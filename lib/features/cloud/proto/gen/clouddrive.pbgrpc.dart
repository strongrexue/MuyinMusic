// This is a generated file - do not edit.
//
// Generated from clouddrive.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart' as $0;

import 'clouddrive.pb.dart' as $1;

export 'clouddrive.pb.dart';

@$pb.GrpcServiceName('clouddrive.CloudDriveFileSrv')
class CloudDriveFileSrvClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  CloudDriveFileSrvClient(super.channel, {super.options, super.interceptors});

  /// Public method, no authorization required. Used as a connectivity probe.
  $grpc.ResponseFuture<$1.CloudDriveSystemInfo> getSystemInfo(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getSystemInfo, request, options: options);
  }

  /// Lists one directory level; items arrive as a stream of SubFilesReply.
  $grpc.ResponseStream<$1.SubFilesReply> getSubFiles(
    $1.ListSubFileRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createStreamingCall(
        _$getSubFiles, $async.Stream.fromIterable([request]),
        options: options);
  }

  /// Resolves a playable/downloadable URL for one file path.
  $grpc.ResponseFuture<$1.DownloadUrlPathInfo> getDownloadUrlPath(
    $1.GetDownloadUrlPathRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getDownloadUrlPath, request, options: options);
  }

  // method descriptors

  static final _$getSystemInfo =
      $grpc.ClientMethod<$0.Empty, $1.CloudDriveSystemInfo>(
          '/clouddrive.CloudDriveFileSrv/GetSystemInfo',
          ($0.Empty value) => value.writeToBuffer(),
          $1.CloudDriveSystemInfo.fromBuffer);
  static final _$getSubFiles =
      $grpc.ClientMethod<$1.ListSubFileRequest, $1.SubFilesReply>(
          '/clouddrive.CloudDriveFileSrv/GetSubFiles',
          ($1.ListSubFileRequest value) => value.writeToBuffer(),
          $1.SubFilesReply.fromBuffer);
  static final _$getDownloadUrlPath =
      $grpc.ClientMethod<$1.GetDownloadUrlPathRequest, $1.DownloadUrlPathInfo>(
          '/clouddrive.CloudDriveFileSrv/GetDownloadUrlPath',
          ($1.GetDownloadUrlPathRequest value) => value.writeToBuffer(),
          $1.DownloadUrlPathInfo.fromBuffer);
}

@$pb.GrpcServiceName('clouddrive.CloudDriveFileSrv')
abstract class CloudDriveFileSrvServiceBase extends $grpc.Service {
  $core.String get $name => 'clouddrive.CloudDriveFileSrv';

  CloudDriveFileSrvServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $1.CloudDriveSystemInfo>(
        'GetSystemInfo',
        getSystemInfo_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($1.CloudDriveSystemInfo value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.ListSubFileRequest, $1.SubFilesReply>(
        'GetSubFiles',
        getSubFiles_Pre,
        false,
        true,
        ($core.List<$core.int> value) =>
            $1.ListSubFileRequest.fromBuffer(value),
        ($1.SubFilesReply value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$1.GetDownloadUrlPathRequest,
            $1.DownloadUrlPathInfo>(
        'GetDownloadUrlPath',
        getDownloadUrlPath_Pre,
        false,
        false,
        ($core.List<$core.int> value) =>
            $1.GetDownloadUrlPathRequest.fromBuffer(value),
        ($1.DownloadUrlPathInfo value) => value.writeToBuffer()));
  }

  $async.Future<$1.CloudDriveSystemInfo> getSystemInfo_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return getSystemInfo($call, await $request);
  }

  $async.Future<$1.CloudDriveSystemInfo> getSystemInfo(
      $grpc.ServiceCall call, $0.Empty request);

  $async.Stream<$1.SubFilesReply> getSubFiles_Pre($grpc.ServiceCall $call,
      $async.Future<$1.ListSubFileRequest> $request) async* {
    yield* getSubFiles($call, await $request);
  }

  $async.Stream<$1.SubFilesReply> getSubFiles(
      $grpc.ServiceCall call, $1.ListSubFileRequest request);

  $async.Future<$1.DownloadUrlPathInfo> getDownloadUrlPath_Pre(
      $grpc.ServiceCall $call,
      $async.Future<$1.GetDownloadUrlPathRequest> $request) async {
    return getDownloadUrlPath($call, await $request);
  }

  $async.Future<$1.DownloadUrlPathInfo> getDownloadUrlPath(
      $grpc.ServiceCall call, $1.GetDownloadUrlPathRequest request);
}
