// This is a generated file - do not edit.
//
// Generated from clouddrive.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $2;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'clouddrive.pbenum.dart';

class CloudDriveSystemInfo extends $pb.GeneratedMessage {
  factory CloudDriveSystemInfo({
    $core.bool? isLogin,
    $core.String? userName,
    $core.bool? systemReady,
  }) {
    final result = CloudDriveSystemInfo._();
    if (isLogin != null) result.isLogin = isLogin;
    if (userName != null) result.userName = userName;
    if (systemReady != null) result.systemReady = systemReady;
    return result;
  }

  CloudDriveSystemInfo._();

  factory CloudDriveSystemInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CloudDriveSystemInfo()..mergeFromBuffer(data, registry);
  factory CloudDriveSystemInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CloudDriveSystemInfo()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CloudDriveSystemInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: CloudDriveSystemInfo.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'IsLogin', protoName: 'IsLogin')
    ..aOS(2, _omitFieldNames ? '' : 'UserName', protoName: 'UserName')
    ..aOB(3, _omitFieldNames ? '' : 'SystemReady', protoName: 'SystemReady')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CloudDriveSystemInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CloudDriveSystemInfo copyWith(void Function(CloudDriveSystemInfo) updates) =>
      super.copyWith((message) => updates(message as CloudDriveSystemInfo))
          as CloudDriveSystemInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CloudDriveSystemInfo() / CloudDriveSystemInfo.new instead')
  static CloudDriveSystemInfo create() => CloudDriveSystemInfo._();
  static $pb.GeneratedMessage $_createMessage() => CloudDriveSystemInfo._();
  @$core.override
  CloudDriveSystemInfo createEmptyInstance() => CloudDriveSystemInfo._();
  @$core.pragma('dart2js:noInline')
  static CloudDriveSystemInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CloudDriveSystemInfo>(
          CloudDriveSystemInfo.$_createMessage);
  static CloudDriveSystemInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get isLogin => $_getBF(0);
  @$pb.TagNumber(1)
  set isLogin($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIsLogin() => $_has(0);
  @$pb.TagNumber(1)
  void clearIsLogin() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userName => $_getSZ(1);
  @$pb.TagNumber(2)
  set userName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserName() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get systemReady => $_getBF(2);
  @$pb.TagNumber(3)
  set systemReady($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSystemReady() => $_has(2);
  @$pb.TagNumber(3)
  void clearSystemReady() => $_clearField(3);
}

class ListSubFileRequest extends $pb.GeneratedMessage {
  factory ListSubFileRequest({
    $core.String? path,
    $core.bool? forceRefresh,
    $core.bool? checkExpires,
  }) {
    final result = ListSubFileRequest._();
    if (path != null) result.path = path;
    if (forceRefresh != null) result.forceRefresh = forceRefresh;
    if (checkExpires != null) result.checkExpires = checkExpires;
    return result;
  }

  ListSubFileRequest._();

  factory ListSubFileRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListSubFileRequest()..mergeFromBuffer(data, registry);
  factory ListSubFileRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListSubFileRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListSubFileRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: ListSubFileRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOB(2, _omitFieldNames ? '' : 'forceRefresh', protoName: 'forceRefresh')
    ..aOB(3, _omitFieldNames ? '' : 'checkExpires', protoName: 'checkExpires')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSubFileRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListSubFileRequest copyWith(void Function(ListSubFileRequest) updates) =>
      super.copyWith((message) => updates(message as ListSubFileRequest))
          as ListSubFileRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ListSubFileRequest() / ListSubFileRequest.new instead')
  static ListSubFileRequest create() => ListSubFileRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListSubFileRequest._();
  @$core.override
  ListSubFileRequest createEmptyInstance() => ListSubFileRequest._();
  @$core.pragma('dart2js:noInline')
  static ListSubFileRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListSubFileRequest>(
          ListSubFileRequest.$_createMessage);
  static ListSubFileRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get forceRefresh => $_getBF(1);
  @$pb.TagNumber(2)
  set forceRefresh($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasForceRefresh() => $_has(1);
  @$pb.TagNumber(2)
  void clearForceRefresh() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get checkExpires => $_getBF(2);
  @$pb.TagNumber(3)
  set checkExpires($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCheckExpires() => $_has(2);
  @$pb.TagNumber(3)
  void clearCheckExpires() => $_clearField(3);
}

class SubFilesReply extends $pb.GeneratedMessage {
  factory SubFilesReply({
    $core.Iterable<CloudDriveFile>? subFiles,
  }) {
    final result = SubFilesReply._();
    if (subFiles != null) result.subFiles.addAll(subFiles);
    return result;
  }

  SubFilesReply._();

  factory SubFilesReply.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SubFilesReply()..mergeFromBuffer(data, registry);
  factory SubFilesReply.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SubFilesReply()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SubFilesReply',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: SubFilesReply.$_createMessage)
    ..pPM<CloudDriveFile>(1, _omitFieldNames ? '' : 'subFiles',
        protoName: 'subFiles', subBuilder: CloudDriveFile.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SubFilesReply clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SubFilesReply copyWith(void Function(SubFilesReply) updates) =>
      super.copyWith((message) => updates(message as SubFilesReply))
          as SubFilesReply;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SubFilesReply() / SubFilesReply.new instead')
  static SubFilesReply create() => SubFilesReply._();
  static $pb.GeneratedMessage $_createMessage() => SubFilesReply._();
  @$core.override
  SubFilesReply createEmptyInstance() => SubFilesReply._();
  @$core.pragma('dart2js:noInline')
  static SubFilesReply getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SubFilesReply>(
          SubFilesReply.$_createMessage);
  static SubFilesReply? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<CloudDriveFile> get subFiles => $_getList(0);
}

class CloudDriveFile extends $pb.GeneratedMessage {
  factory CloudDriveFile({
    $core.String? id,
    $core.String? name,
    $core.String? fullPathName,
    $fixnum.Int64? size,
    $2.Timestamp? createTime,
    $2.Timestamp? writeTime,
    $core.String? thumbnailUrl,
    $core.String? previewUrl,
    $core.bool? isDirectory,
    $core.bool? isForbidden,
    $core.Iterable<$core.MapEntry<$core.int, $core.String>>? fileHashes,
    DownloadUrlPathInfo? downloadUrlPath,
  }) {
    final result = CloudDriveFile._();
    if (id != null) result.id = id;
    if (name != null) result.name = name;
    if (fullPathName != null) result.fullPathName = fullPathName;
    if (size != null) result.size = size;
    if (createTime != null) result.createTime = createTime;
    if (writeTime != null) result.writeTime = writeTime;
    if (thumbnailUrl != null) result.thumbnailUrl = thumbnailUrl;
    if (previewUrl != null) result.previewUrl = previewUrl;
    if (isDirectory != null) result.isDirectory = isDirectory;
    if (isForbidden != null) result.isForbidden = isForbidden;
    if (fileHashes != null) result.fileHashes.addEntries(fileHashes);
    if (downloadUrlPath != null) result.downloadUrlPath = downloadUrlPath;
    return result;
  }

  CloudDriveFile._();

  factory CloudDriveFile.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CloudDriveFile()..mergeFromBuffer(data, registry);
  factory CloudDriveFile.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CloudDriveFile()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CloudDriveFile',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: CloudDriveFile.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'fullPathName', protoName: 'fullPathName')
    ..aInt64(4, _omitFieldNames ? '' : 'size')
    ..aOM<$2.Timestamp>(6, _omitFieldNames ? '' : 'createTime',
        protoName: 'createTime', subBuilder: $2.Timestamp.$_createMessage)
    ..aOM<$2.Timestamp>(7, _omitFieldNames ? '' : 'writeTime',
        protoName: 'writeTime', subBuilder: $2.Timestamp.$_createMessage)
    ..aOS(10, _omitFieldNames ? '' : 'thumbnailUrl', protoName: 'thumbnailUrl')
    ..aOS(11, _omitFieldNames ? '' : 'previewUrl', protoName: 'previewUrl')
    ..aOB(30, _omitFieldNames ? '' : 'isDirectory', protoName: 'isDirectory')
    ..aOB(36, _omitFieldNames ? '' : 'isForbidden', protoName: 'isForbidden')
    ..m<$core.int, $core.String>(70, _omitFieldNames ? '' : 'fileHashes',
        protoName: 'fileHashes',
        entryClassName: 'CloudDriveFile.FileHashesEntry',
        keyFieldType: $pb.PbFieldType.OU3,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('clouddrive'))
    ..aOM<DownloadUrlPathInfo>(76, _omitFieldNames ? '' : 'downloadUrlPath',
        protoName: 'downloadUrlPath',
        subBuilder: DownloadUrlPathInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CloudDriveFile clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CloudDriveFile copyWith(void Function(CloudDriveFile) updates) =>
      super.copyWith((message) => updates(message as CloudDriveFile))
          as CloudDriveFile;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CloudDriveFile() / CloudDriveFile.new instead')
  static CloudDriveFile create() => CloudDriveFile._();
  static $pb.GeneratedMessage $_createMessage() => CloudDriveFile._();
  @$core.override
  CloudDriveFile createEmptyInstance() => CloudDriveFile._();
  @$core.pragma('dart2js:noInline')
  static CloudDriveFile getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CloudDriveFile>(
          CloudDriveFile.$_createMessage);
  static CloudDriveFile? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get fullPathName => $_getSZ(2);
  @$pb.TagNumber(3)
  set fullPathName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFullPathName() => $_has(2);
  @$pb.TagNumber(3)
  void clearFullPathName() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get size => $_getI64(3);
  @$pb.TagNumber(4)
  set size($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSize() => $_has(3);
  @$pb.TagNumber(4)
  void clearSize() => $_clearField(4);

  @$pb.TagNumber(6)
  $2.Timestamp get createTime => $_getN(4);
  @$pb.TagNumber(6)
  set createTime($2.Timestamp value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasCreateTime() => $_has(4);
  @$pb.TagNumber(6)
  void clearCreateTime() => $_clearField(6);
  @$pb.TagNumber(6)
  $2.Timestamp ensureCreateTime() => $_ensure(4);

  @$pb.TagNumber(7)
  $2.Timestamp get writeTime => $_getN(5);
  @$pb.TagNumber(7)
  set writeTime($2.Timestamp value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasWriteTime() => $_has(5);
  @$pb.TagNumber(7)
  void clearWriteTime() => $_clearField(7);
  @$pb.TagNumber(7)
  $2.Timestamp ensureWriteTime() => $_ensure(5);

  @$pb.TagNumber(10)
  $core.String get thumbnailUrl => $_getSZ(6);
  @$pb.TagNumber(10)
  set thumbnailUrl($core.String value) => $_setString(6, value);
  @$pb.TagNumber(10)
  $core.bool hasThumbnailUrl() => $_has(6);
  @$pb.TagNumber(10)
  void clearThumbnailUrl() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.String get previewUrl => $_getSZ(7);
  @$pb.TagNumber(11)
  set previewUrl($core.String value) => $_setString(7, value);
  @$pb.TagNumber(11)
  $core.bool hasPreviewUrl() => $_has(7);
  @$pb.TagNumber(11)
  void clearPreviewUrl() => $_clearField(11);

  @$pb.TagNumber(30)
  $core.bool get isDirectory => $_getBF(8);
  @$pb.TagNumber(30)
  set isDirectory($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(30)
  $core.bool hasIsDirectory() => $_has(8);
  @$pb.TagNumber(30)
  void clearIsDirectory() => $_clearField(30);

  @$pb.TagNumber(36)
  $core.bool get isForbidden => $_getBF(9);
  @$pb.TagNumber(36)
  set isForbidden($core.bool value) => $_setBool(9, value);
  @$pb.TagNumber(36)
  $core.bool hasIsForbidden() => $_has(9);
  @$pb.TagNumber(36)
  void clearIsForbidden() => $_clearField(36);

  @$pb.TagNumber(70)
  $pb.PbMap<$core.int, $core.String> get fileHashes => $_getMap(10);

  /// Download URL info attached to file items when the server provides it.
  @$pb.TagNumber(76)
  DownloadUrlPathInfo get downloadUrlPath => $_getN(11);
  @$pb.TagNumber(76)
  set downloadUrlPath(DownloadUrlPathInfo value) => $_setField(76, value);
  @$pb.TagNumber(76)
  $core.bool hasDownloadUrlPath() => $_has(11);
  @$pb.TagNumber(76)
  void clearDownloadUrlPath() => $_clearField(76);
  @$pb.TagNumber(76)
  DownloadUrlPathInfo ensureDownloadUrlPath() => $_ensure(11);
}

class GetDownloadUrlPathRequest extends $pb.GeneratedMessage {
  factory GetDownloadUrlPathRequest({
    $core.String? path,
    $core.bool? preview,
    $core.bool? lazyRead,
    $core.bool? getDirectUrl,
  }) {
    final result = GetDownloadUrlPathRequest._();
    if (path != null) result.path = path;
    if (preview != null) result.preview = preview;
    if (lazyRead != null) result.lazyRead = lazyRead;
    if (getDirectUrl != null) result.getDirectUrl = getDirectUrl;
    return result;
  }

  GetDownloadUrlPathRequest._();

  factory GetDownloadUrlPathRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetDownloadUrlPathRequest()..mergeFromBuffer(data, registry);
  factory GetDownloadUrlPathRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetDownloadUrlPathRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetDownloadUrlPathRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: GetDownloadUrlPathRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOB(2, _omitFieldNames ? '' : 'preview')
    ..aOB(3, _omitFieldNames ? '' : 'lazyRead')
    ..aOB(4, _omitFieldNames ? '' : 'getDirectUrl')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetDownloadUrlPathRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetDownloadUrlPathRequest copyWith(
          void Function(GetDownloadUrlPathRequest) updates) =>
      super.copyWith((message) => updates(message as GetDownloadUrlPathRequest))
          as GetDownloadUrlPathRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetDownloadUrlPathRequest() / GetDownloadUrlPathRequest.new instead')
  static GetDownloadUrlPathRequest create() => GetDownloadUrlPathRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetDownloadUrlPathRequest._();
  @$core.override
  GetDownloadUrlPathRequest createEmptyInstance() =>
      GetDownloadUrlPathRequest._();
  @$core.pragma('dart2js:noInline')
  static GetDownloadUrlPathRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetDownloadUrlPathRequest>(
          GetDownloadUrlPathRequest.$_createMessage);
  static GetDownloadUrlPathRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get preview => $_getBF(1);
  @$pb.TagNumber(2)
  set preview($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPreview() => $_has(1);
  @$pb.TagNumber(2)
  void clearPreview() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get lazyRead => $_getBF(2);
  @$pb.TagNumber(3)
  set lazyRead($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLazyRead() => $_has(2);
  @$pb.TagNumber(3)
  void clearLazyRead() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get getDirectUrl => $_getBF(3);
  @$pb.TagNumber(4)
  set getDirectUrl($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasGetDirectUrl() => $_has(3);
  @$pb.TagNumber(4)
  void clearGetDirectUrl() => $_clearField(4);
}

class DownloadUrlPathInfo extends $pb.GeneratedMessage {
  factory DownloadUrlPathInfo({
    $core.String? downloadUrlPath,
    $fixnum.Int64? expiresIn,
    $core.String? directUrl,
    $core.String? userAgent,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>?
        additionalHeaders,
  }) {
    final result = DownloadUrlPathInfo._();
    if (downloadUrlPath != null) result.downloadUrlPath = downloadUrlPath;
    if (expiresIn != null) result.expiresIn = expiresIn;
    if (directUrl != null) result.directUrl = directUrl;
    if (userAgent != null) result.userAgent = userAgent;
    if (additionalHeaders != null)
      result.additionalHeaders.addEntries(additionalHeaders);
    return result;
  }

  DownloadUrlPathInfo._();

  factory DownloadUrlPathInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DownloadUrlPathInfo()..mergeFromBuffer(data, registry);
  factory DownloadUrlPathInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DownloadUrlPathInfo()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DownloadUrlPathInfo',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'clouddrive'),
      createEmptyInstance: DownloadUrlPathInfo.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'downloadUrlPath',
        protoName: 'downloadUrlPath')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'expiresIn', $pb.PbFieldType.OU6,
        protoName: 'expiresIn', defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(3, _omitFieldNames ? '' : 'directUrl', protoName: 'directUrl')
    ..aOS(4, _omitFieldNames ? '' : 'userAgent', protoName: 'userAgent')
    ..m<$core.String, $core.String>(
        5, _omitFieldNames ? '' : 'additionalHeaders',
        protoName: 'additionalHeaders',
        entryClassName: 'DownloadUrlPathInfo.AdditionalHeadersEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('clouddrive'))
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DownloadUrlPathInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DownloadUrlPathInfo copyWith(void Function(DownloadUrlPathInfo) updates) =>
      super.copyWith((message) => updates(message as DownloadUrlPathInfo))
          as DownloadUrlPathInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use DownloadUrlPathInfo() / DownloadUrlPathInfo.new instead')
  static DownloadUrlPathInfo create() => DownloadUrlPathInfo._();
  static $pb.GeneratedMessage $_createMessage() => DownloadUrlPathInfo._();
  @$core.override
  DownloadUrlPathInfo createEmptyInstance() => DownloadUrlPathInfo._();
  @$core.pragma('dart2js:noInline')
  static DownloadUrlPathInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DownloadUrlPathInfo>(
          DownloadUrlPathInfo.$_createMessage);
  static DownloadUrlPathInfo? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get downloadUrlPath => $_getSZ(0);
  @$pb.TagNumber(1)
  set downloadUrlPath($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDownloadUrlPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearDownloadUrlPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get expiresIn => $_getI64(1);
  @$pb.TagNumber(2)
  set expiresIn($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExpiresIn() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpiresIn() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get directUrl => $_getSZ(2);
  @$pb.TagNumber(3)
  set directUrl($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDirectUrl() => $_has(2);
  @$pb.TagNumber(3)
  void clearDirectUrl() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get userAgent => $_getSZ(3);
  @$pb.TagNumber(4)
  set userAgent($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasUserAgent() => $_has(3);
  @$pb.TagNumber(4)
  void clearUserAgent() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbMap<$core.String, $core.String> get additionalHeaders => $_getMap(4);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
