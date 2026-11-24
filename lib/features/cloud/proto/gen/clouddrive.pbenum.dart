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

import 'package:protobuf/protobuf.dart' as $pb;

class CloudDriveFile_HashType extends $pb.ProtobufEnum {
  static const CloudDriveFile_HashType Unknown =
      CloudDriveFile_HashType._(0, _omitEnumNames ? '' : 'Unknown');
  static const CloudDriveFile_HashType Md5 =
      CloudDriveFile_HashType._(1, _omitEnumNames ? '' : 'Md5');
  static const CloudDriveFile_HashType Sha1 =
      CloudDriveFile_HashType._(2, _omitEnumNames ? '' : 'Sha1');
  static const CloudDriveFile_HashType PikPakSha1 =
      CloudDriveFile_HashType._(3, _omitEnumNames ? '' : 'PikPakSha1');

  static const $core.List<CloudDriveFile_HashType> values =
      <CloudDriveFile_HashType>[
    Unknown,
    Md5,
    Sha1,
    PikPakSha1,
  ];

  static final $core.List<CloudDriveFile_HashType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static CloudDriveFile_HashType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const CloudDriveFile_HashType._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
