package com.cyshine.music

import android.media.MediaScannerConnection
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileNotFoundException

internal data class MediaDeleteTarget(
    val path: String,
    val name: String,
    val mediaUri: Uri?,
)

/** Resolve exact document/row identity; never search by a song's display name. */
internal class MediaDeleteTargets(private val context: Context) {
    private val resolver get() = context.contentResolver

    fun resolve(path: String): MediaDeleteTarget {
        val uri = Uri.parse(path)
        if (uri.scheme == "content") {
            val document = DocumentsContract.isDocumentUri(context, uri)
            val projection = if (document) arrayOf(OpenableColumns.DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE) else arrayOf(OpenableColumns.DISPLAY_NAME)
            val name = queryContent(uri, projection)?.use {
                if (!it.moveToFirst()) return@use null
                if (document) check(it.getString(1) != DocumentsContract.Document.MIME_TYPE_DIR) {
                    "不能通过歌曲删除操作删除文件夹"
                }
                it.getString(0)
            } ?: return MediaDeleteTarget(path, uri.lastPathSegment.orEmpty(), null)
            val media = when {
                uri.authority == MediaStore.AUTHORITY -> uri
                Build.VERSION.SDK_INT >= 29 && document ->
                    runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()
                else -> null
            }
            return MediaDeleteTarget(path, name, media?.let { runCatching { audioUri(it) }.getOrNull() })
        }
        val file = file(path)
        if (!isMissing(path)) check(file.isFile) { "只能删除音乐文件" }
        val media = runCatching {
            val projection = if (Build.VERSION.SDK_INT >= 29)
                arrayOf(MediaStore.Audio.Media._ID, MediaStore.MediaColumns.VOLUME_NAME)
                else arrayOf(MediaStore.Audio.Media._ID)
            resolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, projection,
                "${MediaStore.MediaColumns.DATA} = ?", arrayOf(file.absolutePath), null)?.use {
                if (!it.moveToFirst()) return@use null
                val volume = if (Build.VERSION.SDK_INT >= 29) it.getString(1) else "external"
                ContentUris.withAppendedId(MediaStore.Audio.Media.getContentUri(volume), it.getLong(0))
            }
        }.getOrNull()
        return MediaDeleteTarget(path, file.name, media)
    }

    private fun audioUri(uri: Uri): Uri? {
        if (uri.authority != MediaStore.AUTHORITY) return null
        val segments = uri.pathSegments
        if (segments.size == 4 && segments[1] == "audio" && segments[2] == "media" &&
            segments[3].toLongOrNull() != null) return uri
        // getMediaUri can return a Files-table URI. createDeleteRequest accepts
        // audio item URIs, not arbitrary Files-table rows. Verify the type first.
        if (segments.size != 3 || segments[1] != "file") return null
        val audio = resolver.query(uri, arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE), null, null, null)?.use {
            it.moveToFirst() && it.getInt(0) == MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO
        } == true
        if (!audio) return null
        val id = segments[2].toLongOrNull() ?: return null
        return ContentUris.withAppendedId(MediaStore.Audio.Media.getContentUri(segments[0]), id)
    }

    fun isMissing(path: String): Boolean {
        val uri = Uri.parse(path)
        if (uri.scheme == "content") {
            return queryContent(uri, arrayOf(OpenableColumns.DISPLAY_NAME))
                ?.use { !it.moveToFirst() } ?: true
        }
        return try {
            Os.stat(file(path).absolutePath)
            false
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ENOTDIR) true
            else throw error
        }
    }

    private fun queryContent(uri: Uri, projection: Array<String>): Cursor? {
        try {
            return resolver.query(uri, projection, null, null, null)
                ?: error("无法确认文件状态")
        } catch (_: FileNotFoundException) {
            return null
        } catch (error: IllegalArgumentException) {
            if (!DocumentsContract.isTreeUri(uri) ||
                !DocumentsContract.isDocumentUri(context, uri)) throw error
            val id = DocumentsContract.getDocumentId(uri)
            val treeId = DocumentsContract.getTreeDocumentId(uri)
            // FileSystemProvider wraps a missing child in IllegalArgumentException
            // during enforceTree, before queryDocument can return an empty cursor.
            // Binder keeps the cause only in the message. Match this exact child;
            // unrelated provider errors and a missing tree must remain failures.
            val missingChild = "Failed to determine if $id is child of $treeId: " +
                "java.io.FileNotFoundException: Missing file for $id at "
            if (id == treeId || error.message?.startsWith(missingChild) != true) throw error
            val root = DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
            val rootExists = resolver.query(root, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null, null, null)?.use { it.moveToFirst() } == true
            if (!rootExists) throw error
            return null
        }
    }

    fun deleteDirect(target: MediaDeleteTarget) {
        if (isMissing(target.path)) return
        val uri = Uri.parse(target.path)
        var scannedFile: String? = null
        when {
            uri.scheme == "content" && DocumentsContract.isDocumentUri(context, uri) -> {
                check(DocumentsContract.deleteDocument(resolver, uri)) { "文件提供方拒绝删除" }
                // Document deletes bypass MediaStore too; if the document
                // maps to a local path, let the scanner drop any stale row.
                scannedFile = localPathForDocument(uri)
            }
            uri.scheme == "content" -> check(resolver.delete(uri, null, null) > 0) { "文件未删除" }
            target.mediaUri != null -> check(resolver.delete(target.mediaUri, null, null) > 0) { "文件未删除" }
            else -> {
                val localFile = file(target.path)
                // A plain path inside a folder granted through the system
                // picker is not deletable through raw file APIs under scoped
                // storage, even though the tree grant itself allows deleting
                // it. Route those through DocumentsContract; the isMissing
                // check below still verifies the entity is really gone.
                val document = documentUriForLocalFile(localFile)
                if (document != null) {
                    check(DocumentsContract.deleteDocument(resolver, document)) { "文件提供方拒绝删除" }
                } else {
                    check(localFile.delete()) { "文件删除失败，请检查目录授权" }
                }
                scannedFile = localFile.absolutePath
            }
        }
        check(isMissing(target.path)) { "文件仍存在，未标记为删除成功" }
        // File.delete() bypasses MediaStore. Ask the media scanner to remove
        // stale rows so other players do not keep showing a ghost song.
        scannedFile?.let { MediaScannerConnection.scanFile(context, arrayOf(it), null, null) }
    }

    /** Local file for an external-storage document id ("volume:relative/path"). */
    private fun localFileForDocumentId(id: String): File? {
        val parts = id.split(':', limit = 2)
        if (parts.size != 2) return null
        val volumeId = parts[0]
        val root = if (volumeId == "primary") Environment.getExternalStorageDirectory()
            else if (Build.VERSION.SDK_INT >= 30) {
                context.getSystemService(StorageManager::class.java).storageVolumes
                    .firstOrNull { it.uuid.equals(volumeId, ignoreCase = true) }?.directory
            } else File("/storage/$volumeId")
        if (root == null) return null
        val base = root.canonicalFile
        val local = File(base, parts[1]).canonicalFile
        if (local != base && !local.path.startsWith(base.path + File.separator)) return null
        return local
    }

    private fun localPathForDocument(uri: Uri): String? {
        if (uri.authority != "com.android.externalstorage.documents") return null
        if (!DocumentsContract.isDocumentUri(context, uri)) return null
        return localFileForDocumentId(DocumentsContract.getDocumentId(uri))?.path
    }

    /**
     * If [localFile] sits inside a persisted SAF tree grant, return its
     * document URI under that tree so the delete can go through the grant.
     * Only external-storage trees can be mapped back to local paths.
     */
    private fun documentUriForLocalFile(localFile: File): Uri? {
        val target = localFile.canonicalFile
        for (permission in resolver.persistedUriPermissions) {
            if (!permission.isWritePermission) continue
            val tree = permission.uri
            if (tree.authority != "com.android.externalstorage.documents") continue
            if (!DocumentsContract.isTreeUri(tree)) continue
            val treeId = DocumentsContract.getTreeDocumentId(tree)
            val root = localFileForDocumentId(treeId) ?: continue
            if (target == root || !target.path.startsWith(root.path + File.separator)) continue
            val volumeId = treeId.substringBefore(':')
            if (volumeId.isEmpty()) continue
            val rootRelative = treeId.substringAfter(':', "")
            val relative = target.relativeTo(root).path.replace(File.separatorChar, '/')
            val documentId = volumeId + ":" +
                listOf(rootRelative, relative).filter { it.isNotEmpty() }.joinToString("/")
            return DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        }
        return null
    }

    private fun file(path: String): File {
        val uri = Uri.parse(path)
        require(uri.scheme == null || uri.scheme == "file") { "不支持此文件地址" }
        val file = if (uri.scheme == "file") File(requireNotNull(uri.path)) else File(path)
        require(file.isAbsolute) { "文件地址必须为绝对路径" }
        return file
    }
}
