// This is a generated file - do not edit.
//
// Generated from clouddrive.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use cloudDriveSystemInfoDescriptor instead')
const CloudDriveSystemInfo$json = {
  '1': 'CloudDriveSystemInfo',
  '2': [
    {'1': 'IsLogin', '3': 1, '4': 1, '5': 8, '10': 'IsLogin'},
    {'1': 'UserName', '3': 2, '4': 1, '5': 9, '10': 'UserName'},
    {'1': 'SystemReady', '3': 3, '4': 1, '5': 8, '10': 'SystemReady'},
  ],
};

/// Descriptor for `CloudDriveSystemInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cloudDriveSystemInfoDescriptor = $convert.base64Decode(
    'ChRDbG91ZERyaXZlU3lzdGVtSW5mbxIYCgdJc0xvZ2luGAEgASgIUgdJc0xvZ2luEhoKCFVzZX'
    'JOYW1lGAIgASgJUghVc2VyTmFtZRIgCgtTeXN0ZW1SZWFkeRgDIAEoCFILU3lzdGVtUmVhZHk=');

@$core.Deprecated('Use listSubFileRequestDescriptor instead')
const ListSubFileRequest$json = {
  '1': 'ListSubFileRequest',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'forceRefresh', '3': 2, '4': 1, '5': 8, '10': 'forceRefresh'},
    {
      '1': 'checkExpires',
      '3': 3,
      '4': 1,
      '5': 8,
      '9': 0,
      '10': 'checkExpires',
      '17': true
    },
  ],
  '8': [
    {'1': '_checkExpires'},
  ],
};

/// Descriptor for `ListSubFileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listSubFileRequestDescriptor = $convert.base64Decode(
    'ChJMaXN0U3ViRmlsZVJlcXVlc3QSEgoEcGF0aBgBIAEoCVIEcGF0aBIiCgxmb3JjZVJlZnJlc2'
    'gYAiABKAhSDGZvcmNlUmVmcmVzaBInCgxjaGVja0V4cGlyZXMYAyABKAhIAFIMY2hlY2tFeHBp'
    'cmVziAEBQg8KDV9jaGVja0V4cGlyZXM=');

@$core.Deprecated('Use subFilesReplyDescriptor instead')
const SubFilesReply$json = {
  '1': 'SubFilesReply',
  '2': [
    {
      '1': 'subFiles',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.clouddrive.CloudDriveFile',
      '10': 'subFiles'
    },
  ],
};

/// Descriptor for `SubFilesReply`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subFilesReplyDescriptor = $convert.base64Decode(
    'Cg1TdWJGaWxlc1JlcGx5EjYKCHN1YkZpbGVzGAEgAygLMhouY2xvdWRkcml2ZS5DbG91ZERyaX'
    'ZlRmlsZVIIc3ViRmlsZXM=');

@$core.Deprecated('Use cloudDriveFileDescriptor instead')
const CloudDriveFile$json = {
  '1': 'CloudDriveFile',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'fullPathName', '3': 3, '4': 1, '5': 9, '10': 'fullPathName'},
    {'1': 'size', '3': 4, '4': 1, '5': 3, '10': 'size'},
    {
      '1': 'createTime',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createTime'
    },
    {
      '1': 'writeTime',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'writeTime'
    },
    {'1': 'thumbnailUrl', '3': 10, '4': 1, '5': 9, '10': 'thumbnailUrl'},
    {'1': 'previewUrl', '3': 11, '4': 1, '5': 9, '10': 'previewUrl'},
    {'1': 'isDirectory', '3': 30, '4': 1, '5': 8, '10': 'isDirectory'},
    {'1': 'isForbidden', '3': 36, '4': 1, '5': 8, '10': 'isForbidden'},
    {
      '1': 'fileHashes',
      '3': 70,
      '4': 3,
      '5': 11,
      '6': '.clouddrive.CloudDriveFile.FileHashesEntry',
      '10': 'fileHashes'
    },
    {
      '1': 'downloadUrlPath',
      '3': 76,
      '4': 1,
      '5': 11,
      '6': '.clouddrive.DownloadUrlPathInfo',
      '9': 0,
      '10': 'downloadUrlPath',
      '17': true
    },
  ],
  '3': [CloudDriveFile_FileHashesEntry$json],
  '4': [CloudDriveFile_HashType$json],
  '8': [
    {'1': '_downloadUrlPath'},
  ],
};

@$core.Deprecated('Use cloudDriveFileDescriptor instead')
const CloudDriveFile_FileHashesEntry$json = {
  '1': 'FileHashesEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 13, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

@$core.Deprecated('Use cloudDriveFileDescriptor instead')
const CloudDriveFile_HashType$json = {
  '1': 'HashType',
  '2': [
    {'1': 'Unknown', '2': 0},
    {'1': 'Md5', '2': 1},
    {'1': 'Sha1', '2': 2},
    {'1': 'PikPakSha1', '2': 3},
  ],
};

/// Descriptor for `CloudDriveFile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cloudDriveFileDescriptor = $convert.base64Decode(
    'Cg5DbG91ZERyaXZlRmlsZRIOCgJpZBgBIAEoCVICaWQSEgoEbmFtZRgCIAEoCVIEbmFtZRIiCg'
    'xmdWxsUGF0aE5hbWUYAyABKAlSDGZ1bGxQYXRoTmFtZRISCgRzaXplGAQgASgDUgRzaXplEjoK'
    'CmNyZWF0ZVRpbWUYBiABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgpjcmVhdGVUaW'
    '1lEjgKCXdyaXRlVGltZRgHIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSCXdyaXRl'
    'VGltZRIiCgx0aHVtYm5haWxVcmwYCiABKAlSDHRodW1ibmFpbFVybBIeCgpwcmV2aWV3VXJsGA'
    'sgASgJUgpwcmV2aWV3VXJsEiAKC2lzRGlyZWN0b3J5GB4gASgIUgtpc0RpcmVjdG9yeRIgCgtp'
    'c0ZvcmJpZGRlbhgkIAEoCFILaXNGb3JiaWRkZW4SSgoKZmlsZUhhc2hlcxhGIAMoCzIqLmNsb3'
    'VkZHJpdmUuQ2xvdWREcml2ZUZpbGUuRmlsZUhhc2hlc0VudHJ5UgpmaWxlSGFzaGVzEk4KD2Rv'
    'd25sb2FkVXJsUGF0aBhMIAEoCzIfLmNsb3VkZHJpdmUuRG93bmxvYWRVcmxQYXRoSW5mb0gAUg'
    '9kb3dubG9hZFVybFBhdGiIAQEaPQoPRmlsZUhhc2hlc0VudHJ5EhAKA2tleRgBIAEoDVIDa2V5'
    'EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAEiOgoISGFzaFR5cGUSCwoHVW5rbm93bhAAEgcKA0'
    '1kNRABEggKBFNoYTEQAhIOCgpQaWtQYWtTaGExEANCEgoQX2Rvd25sb2FkVXJsUGF0aA==');

@$core.Deprecated('Use getDownloadUrlPathRequestDescriptor instead')
const GetDownloadUrlPathRequest$json = {
  '1': 'GetDownloadUrlPathRequest',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'preview', '3': 2, '4': 1, '5': 8, '10': 'preview'},
    {'1': 'lazy_read', '3': 3, '4': 1, '5': 8, '10': 'lazyRead'},
    {'1': 'get_direct_url', '3': 4, '4': 1, '5': 8, '10': 'getDirectUrl'},
  ],
};

/// Descriptor for `GetDownloadUrlPathRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getDownloadUrlPathRequestDescriptor = $convert.base64Decode(
    'ChlHZXREb3dubG9hZFVybFBhdGhSZXF1ZXN0EhIKBHBhdGgYASABKAlSBHBhdGgSGAoHcHJldm'
    'lldxgCIAEoCFIHcHJldmlldxIbCglsYXp5X3JlYWQYAyABKAhSCGxhenlSZWFkEiQKDmdldF9k'
    'aXJlY3RfdXJsGAQgASgIUgxnZXREaXJlY3RVcmw=');

@$core.Deprecated('Use downloadUrlPathInfoDescriptor instead')
const DownloadUrlPathInfo$json = {
  '1': 'DownloadUrlPathInfo',
  '2': [
    {'1': 'downloadUrlPath', '3': 1, '4': 1, '5': 9, '10': 'downloadUrlPath'},
    {
      '1': 'expiresIn',
      '3': 2,
      '4': 1,
      '5': 4,
      '9': 0,
      '10': 'expiresIn',
      '17': true
    },
    {
      '1': 'directUrl',
      '3': 3,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'directUrl',
      '17': true
    },
    {
      '1': 'userAgent',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 2,
      '10': 'userAgent',
      '17': true
    },
    {
      '1': 'additionalHeaders',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.clouddrive.DownloadUrlPathInfo.AdditionalHeadersEntry',
      '10': 'additionalHeaders'
    },
  ],
  '3': [DownloadUrlPathInfo_AdditionalHeadersEntry$json],
  '8': [
    {'1': '_expiresIn'},
    {'1': '_directUrl'},
    {'1': '_userAgent'},
  ],
};

@$core.Deprecated('Use downloadUrlPathInfoDescriptor instead')
const DownloadUrlPathInfo_AdditionalHeadersEntry$json = {
  '1': 'AdditionalHeadersEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `DownloadUrlPathInfo`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List downloadUrlPathInfoDescriptor = $convert.base64Decode(
    'ChNEb3dubG9hZFVybFBhdGhJbmZvEigKD2Rvd25sb2FkVXJsUGF0aBgBIAEoCVIPZG93bmxvYW'
    'RVcmxQYXRoEiEKCWV4cGlyZXNJbhgCIAEoBEgAUglleHBpcmVzSW6IAQESIQoJZGlyZWN0VXJs'
    'GAMgASgJSAFSCWRpcmVjdFVybIgBARIhCgl1c2VyQWdlbnQYBCABKAlIAlIJdXNlckFnZW50iA'
    'EBEmQKEWFkZGl0aW9uYWxIZWFkZXJzGAUgAygLMjYuY2xvdWRkcml2ZS5Eb3dubG9hZFVybFBh'
    'dGhJbmZvLkFkZGl0aW9uYWxIZWFkZXJzRW50cnlSEWFkZGl0aW9uYWxIZWFkZXJzGkQKFkFkZG'
    'l0aW9uYWxIZWFkZXJzRW50cnkSEAoDa2V5GAEgASgJUgNrZXkSFAoFdmFsdWUYAiABKAlSBXZh'
    'bHVlOgI4AUIMCgpfZXhwaXJlc0luQgwKCl9kaXJlY3RVcmxCDAoKX3VzZXJBZ2VudA==');
