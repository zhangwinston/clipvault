// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $DownloadRecordsTable extends DownloadRecords
    with TableInfo<$DownloadRecordsTable, DownloadRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _tweetIdMeta = const VerificationMeta(
    'tweetId',
  );
  @override
  late final GeneratedColumn<String> tweetId = GeneratedColumn<String>(
    'tweet_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _variantUrlMeta = const VerificationMeta(
    'variantUrl',
  );
  @override
  late final GeneratedColumn<String> variantUrl = GeneratedColumn<String>(
    'variant_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentTypeMeta = const VerificationMeta(
    'contentType',
  );
  @override
  late final GeneratedColumn<String> contentType = GeneratedColumn<String>(
    'content_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bitrateMeta = const VerificationMeta(
    'bitrate',
  );
  @override
  late final GeneratedColumn<int> bitrate = GeneratedColumn<int>(
    'bitrate',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _qualityLabelMeta = const VerificationMeta(
    'qualityLabel',
  );
  @override
  late final GeneratedColumn<String> qualityLabel = GeneratedColumn<String>(
    'quality_label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesTotalMeta = const VerificationMeta(
    'bytesTotal',
  );
  @override
  late final GeneratedColumn<int> bytesTotal = GeneratedColumn<int>(
    'bytes_total',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bytesDoneMeta = const VerificationMeta(
    'bytesDone',
  );
  @override
  late final GeneratedColumn<int> bytesDone = GeneratedColumn<int>(
    'bytes_done',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _speedBpsMeta = const VerificationMeta(
    'speedBps',
  );
  @override
  late final GeneratedColumn<int> speedBps = GeneratedColumn<int>(
    'speed_bps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _activeMsMeta = const VerificationMeta(
    'activeMs',
  );
  @override
  late final GeneratedColumn<int> activeMs = GeneratedColumn<int>(
    'active_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _etaSecMeta = const VerificationMeta('etaSec');
  @override
  late final GeneratedColumn<int> etaSec = GeneratedColumn<int>(
    'eta_sec',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _partPathMeta = const VerificationMeta(
    'partPath',
  );
  @override
  late final GeneratedColumn<String> partPath = GeneratedColumn<String>(
    'part_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _errorCodeMeta = const VerificationMeta(
    'errorCode',
  );
  @override
  late final GeneratedColumn<String> errorCode = GeneratedColumn<String>(
    'error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _autoRetriesMeta = const VerificationMeta(
    'autoRetries',
  );
  @override
  late final GeneratedColumn<int> autoRetries = GeneratedColumn<int>(
    'auto_retries',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _tweetJsonMeta = const VerificationMeta(
    'tweetJson',
  );
  @override
  late final GeneratedColumn<String> tweetJson = GeneratedColumn<String>(
    'tweet_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _albumSavedAtMeta = const VerificationMeta(
    'albumSavedAt',
  );
  @override
  late final GeneratedColumn<DateTime> albumSavedAt = GeneratedColumn<DateTime>(
    'album_saved_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    tweetId,
    variantUrl,
    contentType,
    bitrate,
    width,
    height,
    qualityLabel,
    status,
    bytesTotal,
    bytesDone,
    speedBps,
    activeMs,
    etaSec,
    filePath,
    partPath,
    errorCode,
    autoRetries,
    tweetJson,
    albumSavedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('tweet_id')) {
      context.handle(
        _tweetIdMeta,
        tweetId.isAcceptableOrUnknown(data['tweet_id']!, _tweetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_tweetIdMeta);
    }
    if (data.containsKey('variant_url')) {
      context.handle(
        _variantUrlMeta,
        variantUrl.isAcceptableOrUnknown(data['variant_url']!, _variantUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_variantUrlMeta);
    }
    if (data.containsKey('content_type')) {
      context.handle(
        _contentTypeMeta,
        contentType.isAcceptableOrUnknown(
          data['content_type']!,
          _contentTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentTypeMeta);
    }
    if (data.containsKey('bitrate')) {
      context.handle(
        _bitrateMeta,
        bitrate.isAcceptableOrUnknown(data['bitrate']!, _bitrateMeta),
      );
    } else if (isInserting) {
      context.missing(_bitrateMeta);
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    }
    if (data.containsKey('quality_label')) {
      context.handle(
        _qualityLabelMeta,
        qualityLabel.isAcceptableOrUnknown(
          data['quality_label']!,
          _qualityLabelMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_qualityLabelMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('bytes_total')) {
      context.handle(
        _bytesTotalMeta,
        bytesTotal.isAcceptableOrUnknown(data['bytes_total']!, _bytesTotalMeta),
      );
    }
    if (data.containsKey('bytes_done')) {
      context.handle(
        _bytesDoneMeta,
        bytesDone.isAcceptableOrUnknown(data['bytes_done']!, _bytesDoneMeta),
      );
    }
    if (data.containsKey('speed_bps')) {
      context.handle(
        _speedBpsMeta,
        speedBps.isAcceptableOrUnknown(data['speed_bps']!, _speedBpsMeta),
      );
    }
    if (data.containsKey('active_ms')) {
      context.handle(
        _activeMsMeta,
        activeMs.isAcceptableOrUnknown(data['active_ms']!, _activeMsMeta),
      );
    }
    if (data.containsKey('eta_sec')) {
      context.handle(
        _etaSecMeta,
        etaSec.isAcceptableOrUnknown(data['eta_sec']!, _etaSecMeta),
      );
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    }
    if (data.containsKey('part_path')) {
      context.handle(
        _partPathMeta,
        partPath.isAcceptableOrUnknown(data['part_path']!, _partPathMeta),
      );
    }
    if (data.containsKey('error_code')) {
      context.handle(
        _errorCodeMeta,
        errorCode.isAcceptableOrUnknown(data['error_code']!, _errorCodeMeta),
      );
    }
    if (data.containsKey('auto_retries')) {
      context.handle(
        _autoRetriesMeta,
        autoRetries.isAcceptableOrUnknown(
          data['auto_retries']!,
          _autoRetriesMeta,
        ),
      );
    }
    if (data.containsKey('tweet_json')) {
      context.handle(
        _tweetJsonMeta,
        tweetJson.isAcceptableOrUnknown(data['tweet_json']!, _tweetJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_tweetJsonMeta);
    }
    if (data.containsKey('album_saved_at')) {
      context.handle(
        _albumSavedAtMeta,
        albumSavedAt.isAcceptableOrUnknown(
          data['album_saved_at']!,
          _albumSavedAtMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      tweetId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tweet_id'],
      )!,
      variantUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_url'],
      )!,
      contentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_type'],
      )!,
      bitrate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bitrate'],
      )!,
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      ),
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      ),
      qualityLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quality_label'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      bytesTotal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_total'],
      ),
      bytesDone: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes_done'],
      )!,
      speedBps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}speed_bps'],
      )!,
      activeMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}active_ms'],
      )!,
      etaSec: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}eta_sec'],
      ),
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      ),
      partPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}part_path'],
      ),
      errorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_code'],
      ),
      autoRetries: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}auto_retries'],
      )!,
      tweetJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tweet_json'],
      )!,
      albumSavedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}album_saved_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DownloadRecordsTable createAlias(String alias) {
    return $DownloadRecordsTable(attachedDatabase, alias);
  }
}

class DownloadRecord extends DataClass implements Insertable<DownloadRecord> {
  /// 自增主键。
  final int id;

  /// 推文 ID（16~20 位雪花 ID，TEXT 存储），见 §5.3 tweetId (idx)。
  final String tweetId;

  /// 选中变体的直链（含签名参数，会过期）。
  final String variantUrl;

  /// 容器类型，当前恒为 'mp4'（HLS 裁剪理由见 §12.9）。
  final String contentType;

  /// 码率 bps，如 2176000。
  final int bitrate;

  /// 宽（像素），可空——响应无分辨率字段时由 URL 正则提取。
  final int? width;

  /// 高（像素），可空。
  final int? height;

  /// 清晰度标签，如 '720p (HD)'。
  final String qualityLabel;

  /// 状态取值见 [DownloadStatus]。
  final String status;

  /// 总字节数；未知（未收到 content-length）为 null。
  final int? bytesTotal;

  /// 已完成字节数（断点续传基准）。
  final int bytesDone;

  /// 平滑速率 bps（3 秒滑动窗口）。
  final int speedBps;

  /// 累计活跃毫秒数（仅 running 态累计；排队/暂停/冷却等待不计入）。
  /// 「已用时间」的净时长口径（PRD 3.3），替代按入队时刻墙钟差值的失真算法。
  final int activeMs;

  /// 预计剩余秒数，未知为 null。
  final int? etaSec;

  /// 转正后的最终文件路径（appDocuments/downloads/{tweetId}_{bitrate}.mp4）。
  final String? filePath;

  /// 断点文件路径（同名 .part）；启动恢复扫描依据。
  final String? partPath;

  /// ParseError/DownloadError 错误码（如 'E02'）；仅 failed 态有意义。
  final String? errorCode;

  /// 引擎内部已自动重试次数。
  final int autoRetries;

  /// 推文元数据快照 JSON（历史页离线渲染缩略图/作者/文案/清晰度）。
  final String tweetJson;

  /// 入相册时间；null = 未入相册（被拒降级/未保存）。
  final DateTime? albumSavedAt;

  /// 创建时间。
  final DateTime createdAt;

  /// 更新时间（复合索引 (status, updatedAt) 第二列）。
  final DateTime updatedAt;
  const DownloadRecord({
    required this.id,
    required this.tweetId,
    required this.variantUrl,
    required this.contentType,
    required this.bitrate,
    this.width,
    this.height,
    required this.qualityLabel,
    required this.status,
    this.bytesTotal,
    required this.bytesDone,
    required this.speedBps,
    required this.activeMs,
    this.etaSec,
    this.filePath,
    this.partPath,
    this.errorCode,
    required this.autoRetries,
    required this.tweetJson,
    this.albumSavedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['tweet_id'] = Variable<String>(tweetId);
    map['variant_url'] = Variable<String>(variantUrl);
    map['content_type'] = Variable<String>(contentType);
    map['bitrate'] = Variable<int>(bitrate);
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<int>(width);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<int>(height);
    }
    map['quality_label'] = Variable<String>(qualityLabel);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || bytesTotal != null) {
      map['bytes_total'] = Variable<int>(bytesTotal);
    }
    map['bytes_done'] = Variable<int>(bytesDone);
    map['speed_bps'] = Variable<int>(speedBps);
    map['active_ms'] = Variable<int>(activeMs);
    if (!nullToAbsent || etaSec != null) {
      map['eta_sec'] = Variable<int>(etaSec);
    }
    if (!nullToAbsent || filePath != null) {
      map['file_path'] = Variable<String>(filePath);
    }
    if (!nullToAbsent || partPath != null) {
      map['part_path'] = Variable<String>(partPath);
    }
    if (!nullToAbsent || errorCode != null) {
      map['error_code'] = Variable<String>(errorCode);
    }
    map['auto_retries'] = Variable<int>(autoRetries);
    map['tweet_json'] = Variable<String>(tweetJson);
    if (!nullToAbsent || albumSavedAt != null) {
      map['album_saved_at'] = Variable<DateTime>(albumSavedAt);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  DownloadRecordsCompanion toCompanion(bool nullToAbsent) {
    return DownloadRecordsCompanion(
      id: Value(id),
      tweetId: Value(tweetId),
      variantUrl: Value(variantUrl),
      contentType: Value(contentType),
      bitrate: Value(bitrate),
      width: width == null && nullToAbsent
          ? const Value.absent()
          : Value(width),
      height: height == null && nullToAbsent
          ? const Value.absent()
          : Value(height),
      qualityLabel: Value(qualityLabel),
      status: Value(status),
      bytesTotal: bytesTotal == null && nullToAbsent
          ? const Value.absent()
          : Value(bytesTotal),
      bytesDone: Value(bytesDone),
      speedBps: Value(speedBps),
      activeMs: Value(activeMs),
      etaSec: etaSec == null && nullToAbsent
          ? const Value.absent()
          : Value(etaSec),
      filePath: filePath == null && nullToAbsent
          ? const Value.absent()
          : Value(filePath),
      partPath: partPath == null && nullToAbsent
          ? const Value.absent()
          : Value(partPath),
      errorCode: errorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(errorCode),
      autoRetries: Value(autoRetries),
      tweetJson: Value(tweetJson),
      albumSavedAt: albumSavedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(albumSavedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory DownloadRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadRecord(
      id: serializer.fromJson<int>(json['id']),
      tweetId: serializer.fromJson<String>(json['tweetId']),
      variantUrl: serializer.fromJson<String>(json['variantUrl']),
      contentType: serializer.fromJson<String>(json['contentType']),
      bitrate: serializer.fromJson<int>(json['bitrate']),
      width: serializer.fromJson<int?>(json['width']),
      height: serializer.fromJson<int?>(json['height']),
      qualityLabel: serializer.fromJson<String>(json['qualityLabel']),
      status: serializer.fromJson<String>(json['status']),
      bytesTotal: serializer.fromJson<int?>(json['bytesTotal']),
      bytesDone: serializer.fromJson<int>(json['bytesDone']),
      speedBps: serializer.fromJson<int>(json['speedBps']),
      activeMs: serializer.fromJson<int>(json['activeMs']),
      etaSec: serializer.fromJson<int?>(json['etaSec']),
      filePath: serializer.fromJson<String?>(json['filePath']),
      partPath: serializer.fromJson<String?>(json['partPath']),
      errorCode: serializer.fromJson<String?>(json['errorCode']),
      autoRetries: serializer.fromJson<int>(json['autoRetries']),
      tweetJson: serializer.fromJson<String>(json['tweetJson']),
      albumSavedAt: serializer.fromJson<DateTime?>(json['albumSavedAt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'tweetId': serializer.toJson<String>(tweetId),
      'variantUrl': serializer.toJson<String>(variantUrl),
      'contentType': serializer.toJson<String>(contentType),
      'bitrate': serializer.toJson<int>(bitrate),
      'width': serializer.toJson<int?>(width),
      'height': serializer.toJson<int?>(height),
      'qualityLabel': serializer.toJson<String>(qualityLabel),
      'status': serializer.toJson<String>(status),
      'bytesTotal': serializer.toJson<int?>(bytesTotal),
      'bytesDone': serializer.toJson<int>(bytesDone),
      'speedBps': serializer.toJson<int>(speedBps),
      'activeMs': serializer.toJson<int>(activeMs),
      'etaSec': serializer.toJson<int?>(etaSec),
      'filePath': serializer.toJson<String?>(filePath),
      'partPath': serializer.toJson<String?>(partPath),
      'errorCode': serializer.toJson<String?>(errorCode),
      'autoRetries': serializer.toJson<int>(autoRetries),
      'tweetJson': serializer.toJson<String>(tweetJson),
      'albumSavedAt': serializer.toJson<DateTime?>(albumSavedAt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  DownloadRecord copyWith({
    int? id,
    String? tweetId,
    String? variantUrl,
    String? contentType,
    int? bitrate,
    Value<int?> width = const Value.absent(),
    Value<int?> height = const Value.absent(),
    String? qualityLabel,
    String? status,
    Value<int?> bytesTotal = const Value.absent(),
    int? bytesDone,
    int? speedBps,
    int? activeMs,
    Value<int?> etaSec = const Value.absent(),
    Value<String?> filePath = const Value.absent(),
    Value<String?> partPath = const Value.absent(),
    Value<String?> errorCode = const Value.absent(),
    int? autoRetries,
    String? tweetJson,
    Value<DateTime?> albumSavedAt = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => DownloadRecord(
    id: id ?? this.id,
    tweetId: tweetId ?? this.tweetId,
    variantUrl: variantUrl ?? this.variantUrl,
    contentType: contentType ?? this.contentType,
    bitrate: bitrate ?? this.bitrate,
    width: width.present ? width.value : this.width,
    height: height.present ? height.value : this.height,
    qualityLabel: qualityLabel ?? this.qualityLabel,
    status: status ?? this.status,
    bytesTotal: bytesTotal.present ? bytesTotal.value : this.bytesTotal,
    bytesDone: bytesDone ?? this.bytesDone,
    speedBps: speedBps ?? this.speedBps,
    activeMs: activeMs ?? this.activeMs,
    etaSec: etaSec.present ? etaSec.value : this.etaSec,
    filePath: filePath.present ? filePath.value : this.filePath,
    partPath: partPath.present ? partPath.value : this.partPath,
    errorCode: errorCode.present ? errorCode.value : this.errorCode,
    autoRetries: autoRetries ?? this.autoRetries,
    tweetJson: tweetJson ?? this.tweetJson,
    albumSavedAt: albumSavedAt.present ? albumSavedAt.value : this.albumSavedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DownloadRecord copyWithCompanion(DownloadRecordsCompanion data) {
    return DownloadRecord(
      id: data.id.present ? data.id.value : this.id,
      tweetId: data.tweetId.present ? data.tweetId.value : this.tweetId,
      variantUrl: data.variantUrl.present
          ? data.variantUrl.value
          : this.variantUrl,
      contentType: data.contentType.present
          ? data.contentType.value
          : this.contentType,
      bitrate: data.bitrate.present ? data.bitrate.value : this.bitrate,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      qualityLabel: data.qualityLabel.present
          ? data.qualityLabel.value
          : this.qualityLabel,
      status: data.status.present ? data.status.value : this.status,
      bytesTotal: data.bytesTotal.present
          ? data.bytesTotal.value
          : this.bytesTotal,
      bytesDone: data.bytesDone.present ? data.bytesDone.value : this.bytesDone,
      speedBps: data.speedBps.present ? data.speedBps.value : this.speedBps,
      activeMs: data.activeMs.present ? data.activeMs.value : this.activeMs,
      etaSec: data.etaSec.present ? data.etaSec.value : this.etaSec,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      partPath: data.partPath.present ? data.partPath.value : this.partPath,
      errorCode: data.errorCode.present ? data.errorCode.value : this.errorCode,
      autoRetries: data.autoRetries.present
          ? data.autoRetries.value
          : this.autoRetries,
      tweetJson: data.tweetJson.present ? data.tweetJson.value : this.tweetJson,
      albumSavedAt: data.albumSavedAt.present
          ? data.albumSavedAt.value
          : this.albumSavedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadRecord(')
          ..write('id: $id, ')
          ..write('tweetId: $tweetId, ')
          ..write('variantUrl: $variantUrl, ')
          ..write('contentType: $contentType, ')
          ..write('bitrate: $bitrate, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('qualityLabel: $qualityLabel, ')
          ..write('status: $status, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('bytesDone: $bytesDone, ')
          ..write('speedBps: $speedBps, ')
          ..write('activeMs: $activeMs, ')
          ..write('etaSec: $etaSec, ')
          ..write('filePath: $filePath, ')
          ..write('partPath: $partPath, ')
          ..write('errorCode: $errorCode, ')
          ..write('autoRetries: $autoRetries, ')
          ..write('tweetJson: $tweetJson, ')
          ..write('albumSavedAt: $albumSavedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    tweetId,
    variantUrl,
    contentType,
    bitrate,
    width,
    height,
    qualityLabel,
    status,
    bytesTotal,
    bytesDone,
    speedBps,
    activeMs,
    etaSec,
    filePath,
    partPath,
    errorCode,
    autoRetries,
    tweetJson,
    albumSavedAt,
    createdAt,
    updatedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadRecord &&
          other.id == this.id &&
          other.tweetId == this.tweetId &&
          other.variantUrl == this.variantUrl &&
          other.contentType == this.contentType &&
          other.bitrate == this.bitrate &&
          other.width == this.width &&
          other.height == this.height &&
          other.qualityLabel == this.qualityLabel &&
          other.status == this.status &&
          other.bytesTotal == this.bytesTotal &&
          other.bytesDone == this.bytesDone &&
          other.speedBps == this.speedBps &&
          other.activeMs == this.activeMs &&
          other.etaSec == this.etaSec &&
          other.filePath == this.filePath &&
          other.partPath == this.partPath &&
          other.errorCode == this.errorCode &&
          other.autoRetries == this.autoRetries &&
          other.tweetJson == this.tweetJson &&
          other.albumSavedAt == this.albumSavedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class DownloadRecordsCompanion extends UpdateCompanion<DownloadRecord> {
  final Value<int> id;
  final Value<String> tweetId;
  final Value<String> variantUrl;
  final Value<String> contentType;
  final Value<int> bitrate;
  final Value<int?> width;
  final Value<int?> height;
  final Value<String> qualityLabel;
  final Value<String> status;
  final Value<int?> bytesTotal;
  final Value<int> bytesDone;
  final Value<int> speedBps;
  final Value<int> activeMs;
  final Value<int?> etaSec;
  final Value<String?> filePath;
  final Value<String?> partPath;
  final Value<String?> errorCode;
  final Value<int> autoRetries;
  final Value<String> tweetJson;
  final Value<DateTime?> albumSavedAt;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  const DownloadRecordsCompanion({
    this.id = const Value.absent(),
    this.tweetId = const Value.absent(),
    this.variantUrl = const Value.absent(),
    this.contentType = const Value.absent(),
    this.bitrate = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.qualityLabel = const Value.absent(),
    this.status = const Value.absent(),
    this.bytesTotal = const Value.absent(),
    this.bytesDone = const Value.absent(),
    this.speedBps = const Value.absent(),
    this.activeMs = const Value.absent(),
    this.etaSec = const Value.absent(),
    this.filePath = const Value.absent(),
    this.partPath = const Value.absent(),
    this.errorCode = const Value.absent(),
    this.autoRetries = const Value.absent(),
    this.tweetJson = const Value.absent(),
    this.albumSavedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  DownloadRecordsCompanion.insert({
    this.id = const Value.absent(),
    required String tweetId,
    required String variantUrl,
    required String contentType,
    required int bitrate,
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    required String qualityLabel,
    required String status,
    this.bytesTotal = const Value.absent(),
    this.bytesDone = const Value.absent(),
    this.speedBps = const Value.absent(),
    this.activeMs = const Value.absent(),
    this.etaSec = const Value.absent(),
    this.filePath = const Value.absent(),
    this.partPath = const Value.absent(),
    this.errorCode = const Value.absent(),
    this.autoRetries = const Value.absent(),
    required String tweetJson,
    this.albumSavedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  }) : tweetId = Value(tweetId),
       variantUrl = Value(variantUrl),
       contentType = Value(contentType),
       bitrate = Value(bitrate),
       qualityLabel = Value(qualityLabel),
       status = Value(status),
       tweetJson = Value(tweetJson);
  static Insertable<DownloadRecord> custom({
    Expression<int>? id,
    Expression<String>? tweetId,
    Expression<String>? variantUrl,
    Expression<String>? contentType,
    Expression<int>? bitrate,
    Expression<int>? width,
    Expression<int>? height,
    Expression<String>? qualityLabel,
    Expression<String>? status,
    Expression<int>? bytesTotal,
    Expression<int>? bytesDone,
    Expression<int>? speedBps,
    Expression<int>? activeMs,
    Expression<int>? etaSec,
    Expression<String>? filePath,
    Expression<String>? partPath,
    Expression<String>? errorCode,
    Expression<int>? autoRetries,
    Expression<String>? tweetJson,
    Expression<DateTime>? albumSavedAt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (tweetId != null) 'tweet_id': tweetId,
      if (variantUrl != null) 'variant_url': variantUrl,
      if (contentType != null) 'content_type': contentType,
      if (bitrate != null) 'bitrate': bitrate,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (qualityLabel != null) 'quality_label': qualityLabel,
      if (status != null) 'status': status,
      if (bytesTotal != null) 'bytes_total': bytesTotal,
      if (bytesDone != null) 'bytes_done': bytesDone,
      if (speedBps != null) 'speed_bps': speedBps,
      if (activeMs != null) 'active_ms': activeMs,
      if (etaSec != null) 'eta_sec': etaSec,
      if (filePath != null) 'file_path': filePath,
      if (partPath != null) 'part_path': partPath,
      if (errorCode != null) 'error_code': errorCode,
      if (autoRetries != null) 'auto_retries': autoRetries,
      if (tweetJson != null) 'tweet_json': tweetJson,
      if (albumSavedAt != null) 'album_saved_at': albumSavedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  DownloadRecordsCompanion copyWith({
    Value<int>? id,
    Value<String>? tweetId,
    Value<String>? variantUrl,
    Value<String>? contentType,
    Value<int>? bitrate,
    Value<int?>? width,
    Value<int?>? height,
    Value<String>? qualityLabel,
    Value<String>? status,
    Value<int?>? bytesTotal,
    Value<int>? bytesDone,
    Value<int>? speedBps,
    Value<int>? activeMs,
    Value<int?>? etaSec,
    Value<String?>? filePath,
    Value<String?>? partPath,
    Value<String?>? errorCode,
    Value<int>? autoRetries,
    Value<String>? tweetJson,
    Value<DateTime?>? albumSavedAt,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
  }) {
    return DownloadRecordsCompanion(
      id: id ?? this.id,
      tweetId: tweetId ?? this.tweetId,
      variantUrl: variantUrl ?? this.variantUrl,
      contentType: contentType ?? this.contentType,
      bitrate: bitrate ?? this.bitrate,
      width: width ?? this.width,
      height: height ?? this.height,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      status: status ?? this.status,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      bytesDone: bytesDone ?? this.bytesDone,
      speedBps: speedBps ?? this.speedBps,
      activeMs: activeMs ?? this.activeMs,
      etaSec: etaSec ?? this.etaSec,
      filePath: filePath ?? this.filePath,
      partPath: partPath ?? this.partPath,
      errorCode: errorCode ?? this.errorCode,
      autoRetries: autoRetries ?? this.autoRetries,
      tweetJson: tweetJson ?? this.tweetJson,
      albumSavedAt: albumSavedAt ?? this.albumSavedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (tweetId.present) {
      map['tweet_id'] = Variable<String>(tweetId.value);
    }
    if (variantUrl.present) {
      map['variant_url'] = Variable<String>(variantUrl.value);
    }
    if (contentType.present) {
      map['content_type'] = Variable<String>(contentType.value);
    }
    if (bitrate.present) {
      map['bitrate'] = Variable<int>(bitrate.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (qualityLabel.present) {
      map['quality_label'] = Variable<String>(qualityLabel.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (bytesTotal.present) {
      map['bytes_total'] = Variable<int>(bytesTotal.value);
    }
    if (bytesDone.present) {
      map['bytes_done'] = Variable<int>(bytesDone.value);
    }
    if (speedBps.present) {
      map['speed_bps'] = Variable<int>(speedBps.value);
    }
    if (activeMs.present) {
      map['active_ms'] = Variable<int>(activeMs.value);
    }
    if (etaSec.present) {
      map['eta_sec'] = Variable<int>(etaSec.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (partPath.present) {
      map['part_path'] = Variable<String>(partPath.value);
    }
    if (errorCode.present) {
      map['error_code'] = Variable<String>(errorCode.value);
    }
    if (autoRetries.present) {
      map['auto_retries'] = Variable<int>(autoRetries.value);
    }
    if (tweetJson.present) {
      map['tweet_json'] = Variable<String>(tweetJson.value);
    }
    if (albumSavedAt.present) {
      map['album_saved_at'] = Variable<DateTime>(albumSavedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadRecordsCompanion(')
          ..write('id: $id, ')
          ..write('tweetId: $tweetId, ')
          ..write('variantUrl: $variantUrl, ')
          ..write('contentType: $contentType, ')
          ..write('bitrate: $bitrate, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('qualityLabel: $qualityLabel, ')
          ..write('status: $status, ')
          ..write('bytesTotal: $bytesTotal, ')
          ..write('bytesDone: $bytesDone, ')
          ..write('speedBps: $speedBps, ')
          ..write('activeMs: $activeMs, ')
          ..write('etaSec: $etaSec, ')
          ..write('filePath: $filePath, ')
          ..write('partPath: $partPath, ')
          ..write('errorCode: $errorCode, ')
          ..write('autoRetries: $autoRetries, ')
          ..write('tweetJson: $tweetJson, ')
          ..write('albumSavedAt: $albumSavedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DownloadRecordsTable downloadRecords = $DownloadRecordsTable(
    this,
  );
  late final Index idxDownloadRecordsTweetId = Index(
    'idx_download_records_tweet_id',
    'CREATE INDEX idx_download_records_tweet_id ON download_records (tweet_id)',
  );
  late final Index idxDownloadRecordsStatusUpdatedAt = Index(
    'idx_download_records_status_updated_at',
    'CREATE INDEX idx_download_records_status_updated_at ON download_records (status, updated_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    downloadRecords,
    idxDownloadRecordsTweetId,
    idxDownloadRecordsStatusUpdatedAt,
  ];
}

typedef $$DownloadRecordsTableCreateCompanionBuilder =
    DownloadRecordsCompanion Function({
      Value<int> id,
      required String tweetId,
      required String variantUrl,
      required String contentType,
      required int bitrate,
      Value<int?> width,
      Value<int?> height,
      required String qualityLabel,
      required String status,
      Value<int?> bytesTotal,
      Value<int> bytesDone,
      Value<int> speedBps,
      Value<int> activeMs,
      Value<int?> etaSec,
      Value<String?> filePath,
      Value<String?> partPath,
      Value<String?> errorCode,
      Value<int> autoRetries,
      required String tweetJson,
      Value<DateTime?> albumSavedAt,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });
typedef $$DownloadRecordsTableUpdateCompanionBuilder =
    DownloadRecordsCompanion Function({
      Value<int> id,
      Value<String> tweetId,
      Value<String> variantUrl,
      Value<String> contentType,
      Value<int> bitrate,
      Value<int?> width,
      Value<int?> height,
      Value<String> qualityLabel,
      Value<String> status,
      Value<int?> bytesTotal,
      Value<int> bytesDone,
      Value<int> speedBps,
      Value<int> activeMs,
      Value<int?> etaSec,
      Value<String?> filePath,
      Value<String?> partPath,
      Value<String?> errorCode,
      Value<int> autoRetries,
      Value<String> tweetJson,
      Value<DateTime?> albumSavedAt,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
    });

class $$DownloadRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadRecordsTable> {
  $$DownloadRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tweetId => $composableBuilder(
    column: $table.tweetId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantUrl => $composableBuilder(
    column: $table.variantUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bitrate => $composableBuilder(
    column: $table.bitrate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get qualityLabel => $composableBuilder(
    column: $table.qualityLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytesDone => $composableBuilder(
    column: $table.bytesDone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get speedBps => $composableBuilder(
    column: $table.speedBps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get activeMs => $composableBuilder(
    column: $table.activeMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get etaSec => $composableBuilder(
    column: $table.etaSec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partPath => $composableBuilder(
    column: $table.partPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get autoRetries => $composableBuilder(
    column: $table.autoRetries,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tweetJson => $composableBuilder(
    column: $table.tweetJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get albumSavedAt => $composableBuilder(
    column: $table.albumSavedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadRecordsTable> {
  $$DownloadRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tweetId => $composableBuilder(
    column: $table.tweetId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantUrl => $composableBuilder(
    column: $table.variantUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bitrate => $composableBuilder(
    column: $table.bitrate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get qualityLabel => $composableBuilder(
    column: $table.qualityLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytesDone => $composableBuilder(
    column: $table.bytesDone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get speedBps => $composableBuilder(
    column: $table.speedBps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get activeMs => $composableBuilder(
    column: $table.activeMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get etaSec => $composableBuilder(
    column: $table.etaSec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partPath => $composableBuilder(
    column: $table.partPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorCode => $composableBuilder(
    column: $table.errorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get autoRetries => $composableBuilder(
    column: $table.autoRetries,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tweetJson => $composableBuilder(
    column: $table.tweetJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get albumSavedAt => $composableBuilder(
    column: $table.albumSavedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadRecordsTable> {
  $$DownloadRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get tweetId =>
      $composableBuilder(column: $table.tweetId, builder: (column) => column);

  GeneratedColumn<String> get variantUrl => $composableBuilder(
    column: $table.variantUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get bitrate =>
      $composableBuilder(column: $table.bitrate, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<String> get qualityLabel => $composableBuilder(
    column: $table.qualityLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get bytesTotal => $composableBuilder(
    column: $table.bytesTotal,
    builder: (column) => column,
  );

  GeneratedColumn<int> get bytesDone =>
      $composableBuilder(column: $table.bytesDone, builder: (column) => column);

  GeneratedColumn<int> get speedBps =>
      $composableBuilder(column: $table.speedBps, builder: (column) => column);

  GeneratedColumn<int> get activeMs =>
      $composableBuilder(column: $table.activeMs, builder: (column) => column);

  GeneratedColumn<int> get etaSec =>
      $composableBuilder(column: $table.etaSec, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<String> get partPath =>
      $composableBuilder(column: $table.partPath, builder: (column) => column);

  GeneratedColumn<String> get errorCode =>
      $composableBuilder(column: $table.errorCode, builder: (column) => column);

  GeneratedColumn<int> get autoRetries => $composableBuilder(
    column: $table.autoRetries,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tweetJson =>
      $composableBuilder(column: $table.tweetJson, builder: (column) => column);

  GeneratedColumn<DateTime> get albumSavedAt => $composableBuilder(
    column: $table.albumSavedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DownloadRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadRecordsTable,
          DownloadRecord,
          $$DownloadRecordsTableFilterComposer,
          $$DownloadRecordsTableOrderingComposer,
          $$DownloadRecordsTableAnnotationComposer,
          $$DownloadRecordsTableCreateCompanionBuilder,
          $$DownloadRecordsTableUpdateCompanionBuilder,
          (
            DownloadRecord,
            BaseReferences<
              _$AppDatabase,
              $DownloadRecordsTable,
              DownloadRecord
            >,
          ),
          DownloadRecord,
          PrefetchHooks Function()
        > {
  $$DownloadRecordsTableTableManager(
    _$AppDatabase db,
    $DownloadRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> tweetId = const Value.absent(),
                Value<String> variantUrl = const Value.absent(),
                Value<String> contentType = const Value.absent(),
                Value<int> bitrate = const Value.absent(),
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<String> qualityLabel = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int?> bytesTotal = const Value.absent(),
                Value<int> bytesDone = const Value.absent(),
                Value<int> speedBps = const Value.absent(),
                Value<int> activeMs = const Value.absent(),
                Value<int?> etaSec = const Value.absent(),
                Value<String?> filePath = const Value.absent(),
                Value<String?> partPath = const Value.absent(),
                Value<String?> errorCode = const Value.absent(),
                Value<int> autoRetries = const Value.absent(),
                Value<String> tweetJson = const Value.absent(),
                Value<DateTime?> albumSavedAt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => DownloadRecordsCompanion(
                id: id,
                tweetId: tweetId,
                variantUrl: variantUrl,
                contentType: contentType,
                bitrate: bitrate,
                width: width,
                height: height,
                qualityLabel: qualityLabel,
                status: status,
                bytesTotal: bytesTotal,
                bytesDone: bytesDone,
                speedBps: speedBps,
                activeMs: activeMs,
                etaSec: etaSec,
                filePath: filePath,
                partPath: partPath,
                errorCode: errorCode,
                autoRetries: autoRetries,
                tweetJson: tweetJson,
                albumSavedAt: albumSavedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String tweetId,
                required String variantUrl,
                required String contentType,
                required int bitrate,
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                required String qualityLabel,
                required String status,
                Value<int?> bytesTotal = const Value.absent(),
                Value<int> bytesDone = const Value.absent(),
                Value<int> speedBps = const Value.absent(),
                Value<int> activeMs = const Value.absent(),
                Value<int?> etaSec = const Value.absent(),
                Value<String?> filePath = const Value.absent(),
                Value<String?> partPath = const Value.absent(),
                Value<String?> errorCode = const Value.absent(),
                Value<int> autoRetries = const Value.absent(),
                required String tweetJson,
                Value<DateTime?> albumSavedAt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => DownloadRecordsCompanion.insert(
                id: id,
                tweetId: tweetId,
                variantUrl: variantUrl,
                contentType: contentType,
                bitrate: bitrate,
                width: width,
                height: height,
                qualityLabel: qualityLabel,
                status: status,
                bytesTotal: bytesTotal,
                bytesDone: bytesDone,
                speedBps: speedBps,
                activeMs: activeMs,
                etaSec: etaSec,
                filePath: filePath,
                partPath: partPath,
                errorCode: errorCode,
                autoRetries: autoRetries,
                tweetJson: tweetJson,
                albumSavedAt: albumSavedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DownloadRecordsTable, DownloadRecord>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $DownloadRecordsTable,
                    DownloadRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadRecordsTable,
      DownloadRecord,
      $$DownloadRecordsTableFilterComposer,
      $$DownloadRecordsTableOrderingComposer,
      $$DownloadRecordsTableAnnotationComposer,
      $$DownloadRecordsTableCreateCompanionBuilder,
      $$DownloadRecordsTableUpdateCompanionBuilder,
      (
        DownloadRecord,
        BaseReferences<_$AppDatabase, $DownloadRecordsTable, DownloadRecord>,
      ),
      DownloadRecord,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DownloadRecordsTableTableManager get downloadRecords =>
      $$DownloadRecordsTableTableManager(_db, _db.downloadRecords);
}
