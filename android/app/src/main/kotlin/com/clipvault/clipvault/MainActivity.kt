package com.clipvault.clipvault

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 历史备份原生通道（DESIGN §4.7「卸载重装保留历史」方案层②）。
 *
 * 为什么用 MediaStore Downloads 而非应用私有目录：私有目录随卸载删除；
 * 而写入公共 Downloads/ClipVault 的文件卸载后保留，且**同包名重装后
 * owner 复联、免任何运行时权限即可读回**（API 29+ 自有贡献文件规则）。
 * 相册里的已下载视频（gal 写入 Movies/ClipVault）同理可按文件名回查。
 *
 * API < 29 无 MediaStore Downloads 集合，通道整体报不支持（Dart 层
 * 回落 Documents 目录实现，见 lib/backup/）。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "clipvault/backup"
        const val NETWORK_CHANNEL = "clipvault/network"

        /** 备份文件名前缀（读取按前缀取最新：同名 json 与名称冲突时的
         *  时间戳回退名都能命中，2026-10-07） */
        const val BACKUP_PREFIX = "clipvault_backup"

        /** 常规备份文件名（快路径删旧插新，常态单文件） */
        const val BACKUP_NAME = "clipvault_backup.json"

        /** 诊断日志 tag（「备份失败」双层吞错后 logcat 侧的根因出口） */
        const val TAG = "ClipVaultBackup"

        // Environment.DIRECTORY_DOWNLOADS 的字面量（"Download"）——Java 静态
        // 字段对 Kotlin const 非编译期常量，这里取字面量保持 const 语义
        const val BACKUP_RELATIVE_DIR = "Download/ClipVault"

        /** SAF 兜底恢复的文件选择请求码 */
        const val REQ_PICK_BACKUP = 4711

        /** 相册视频读权限的请求码（重装恢复视频路径复活） */
        const val REQ_VIDEO_READ = 4712
    }

    /** SAF 选择备份文件的挂起通道结果（onActivityResult 回填）。 */
    private var pendingBackupPick: MethodChannel.Result? = null

    /** 运行时权限请求的挂起通道结果（onRequestPermissionsResult 回填）。 */
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isSupported" -> result.success(Build.VERSION.SDK_INT >= 29)
                    "writeBackup" -> result.success(
                        writeBackup(call.argument<String>("json") ?: "")
                    )
                    "readBackup" -> result.success(readBackup())
                    "findVideoPathByName" -> result.success(
                        findVideoPathByName(call.argument<String>("name") ?: "")
                    )
                    "pickAndReadBackup" -> {
                        // SAF 兜底：跨卸载后旧备份文件所有权不归属新安装
                        // （2026-10-05 实证：Android 11+ 同包名重装不自动复联
                        // owner，Downloads 非媒体孤儿行对无权限 App 不可见），
                        // 直读必失败——弹系统文件选择器，选中即获临时读授权。
                        // EXTRA_INITIAL_URI 预定位到 Download/ClipVault，两步点完
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf("application/json", "application/octet-stream"),
                            )
                            try {
                                putExtra(
                                    DocumentsContract.EXTRA_INITIAL_URI,
                                    DocumentsContract.buildDocumentUri(
                                        "com.android.externalstorage.documents",
                                        "primary:Download/ClipVault",
                                    ),
                                )
                            } catch (_: Exception) {
                                // 个别 ROM 不认初始 URI：回落默认目录，无害
                            }
                        }
                        pendingBackupPick = result
                        startActivityForResult(intent, REQ_PICK_BACKUP)
                    }
                    "requestVideoReadPermission" -> {
                        // 重装恢复场景：Movies/ClipVault 的已下载视频与备份
                        // 同为孤儿，授权相册读权限后 MediaStore 才可见可读
                        requestVideoReadPermission(result)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // 任一原生异常都不上抛为崩溃：备份是增强能力，失败静默降级
                result.error("backup_error", e.message, null)
            }
        }
        // 系统代理解析（DESIGN §6.9）：dart:io HttpClient 默认不读系统
        // Wi-Fi 代理，App 直连被代理环境阻断 → Dart 侧经此通道取代理。
        MethodChannel(engine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> {
                        // Wi-Fi 手动代理由框架注入应用进程的 JVM 属性；
                        // VPN(TUN) 模式代理在 IP 层透明转发，无需此机制
                        val host = System.getProperty("http.proxyHost")
                        val portStr = System.getProperty("http.proxyPort")
                        val port = portStr?.toIntOrNull() ?: -1
                        if (!host.isNullOrBlank() && port in 1..65535) {
                            result.success(mapOf("host" to host, "port" to port))
                        } else {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 查询 Downloads/ClipVault 下最新的备份 Uri（前缀匹配：同名 json 与
     *  时间戳回退名都命中；跨安装可见性同前——仅自有贡献行）。 */
    private fun queryBackupUri(): Uri? {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} LIKE ?"
        val latest = contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            arrayOf("$BACKUP_PREFIX%"),
            "${MediaStore.Downloads.DATE_MODIFIED} DESC",
        ) ?: return null
        latest.use { c ->
            if (!c.moveToFirst()) return null
            val id = c.getLong(0)
            return Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toString())
        }
    }

    /**
     * 全量重写备份（先删自己的旧行再插入，避免多行并存与半写状态）。
     *
     * 返回失败原因描述（空串 = 成功）——2026-10-07 真机二轮排查：双层
     * 吞错后 logcat 与 UI 均无从定位，改为原因直通 UI。
     *
     * insert 三级回退：①同名（常态单文件）→ ②时间戳名（DISPLAY_NAME
     * 冲突/ROM 拒绝）→ ③Download 根目录（子目录路径个别 ROM 不接受）。
     * 读取侧前缀匹配取最新，三种落位都能读到。
     */
    private fun writeBackup(json: String): String {
        if (Build.VERSION.SDK_INT < 29) return "SDK<29 无 MediaStore Downloads"
        if (json.isEmpty()) return "备份载荷为空"
        val existing = queryBackupUri()
        if (existing != null) {
            try {
                contentResolver.delete(existing, null, null)
            } catch (_: SecurityException) {
                // 旧安装遗留且 owner 未复联（签名变更等极端场景）：不删，
                // 直接另插新行，读取侧按修改时间取最新。
            }
        }
        val uri = insertPending(BACKUP_NAME)
            ?: insertPending("${BACKUP_PREFIX}-${System.currentTimeMillis()}.json")
            ?: insertPending(
                "${BACKUP_PREFIX}-${System.currentTimeMillis()}.json",
                subDir = false,
            )
        if (uri == null) {
            val reason = "insert 三级均失败（同名/时间戳/根目录）"
            Log.w(TAG, reason)
            return reason
        }
        try {
            val stream = contentResolver.openOutputStream(uri)
            if (stream == null) {
                Log.w(TAG, "openOutputStream 返回空")
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
                return "openOutputStream 返回空"
            }
            stream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            val published = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            contentResolver.update(uri, published, null, null)
        } catch (e: Exception) {
            Log.w(TAG, "备份写入/发布失败", e)
            // 清理半写行，避免残留 pending 挡住下一轮
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            return "写入/发布异常: ${e.message}"
        }
        cleanupStaleRows(keep = uri)
        return ""
    }

    /** 插入一条 pending 备份行；异常/拒绝返回 null（调用方回退重试）。 */
    private fun insertPending(name: String, subDir: Boolean = true): Uri? = try {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/json")
            put(
                MediaStore.Downloads.RELATIVE_PATH,
                if (subDir) BACKUP_RELATIVE_DIR else Environment.DIRECTORY_DOWNLOADS,
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
    } catch (e: Exception) {
        Log.w(TAG, "insert 异常（$name subDir=$subDir）: ${e.message}")
        null
    }

    /** 清理自己的其余备份行（时间戳回退名等），best-effort（非自己行静默跳过）。 */
    private fun cleanupStaleRows(keep: Uri) {
        try {
            val cursor = contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME} LIKE ?",
                arrayOf("$BACKUP_PREFIX%"),
                "${MediaStore.Downloads.DATE_MODIFIED} DESC",
            ) ?: return
            cursor.use { c ->
                while (c.moveToNext()) {
                    val uri = Uri.withAppendedPath(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        c.getLong(0).toString(),
                    )
                    if (uri == keep) continue
                    try {
                        contentResolver.delete(uri, null, null)
                    } catch (_: SecurityException) {
                        // 非本安装贡献的行：留给 SAF 兜底通道
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    /** 读回备份；不存在或不可读（owner 未复联）返回 null。 */
    private fun readBackup(): String? {
        if (Build.VERSION.SDK_INT < 29) return null
        val uri = queryBackupUri() ?: return null
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * 按显示名回查视频的绝对路径（相册 Movies/ClipVault 中由 gal 写入、
     * 文件名约定 {tweetId}_{bitrate}.mp4）。同包名重装后自有贡献可直读。
     */
    private fun findVideoPathByName(name: String): String? {
        if (Build.VERSION.SDK_INT < 29 || name.isEmpty()) return null
        val projection = arrayOf(MediaStore.Video.Media.DATA)
        val selection = "${MediaStore.Video.Media.DISPLAY_NAME} = ?"
        val latest = contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            arrayOf(name),
            "${MediaStore.Video.Media.DATE_MODIFIED} DESC",
        ) ?: return null
        latest.use { c ->
            if (!c.moveToFirst()) return null
            return c.getString(0)
        }
    }

    /** SAF 选中的备份文件经临时授权读回（用户取消/读取失败 → null）。 */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_BACKUP) {
            val pending = pendingBackupPick ?: return
            pendingBackupPick = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            try {
                val text = contentResolver.openInputStream(uri)
                    ?.use { it.readBytes().toString(Charsets.UTF_8) }
                pending.success(text)
            } catch (_: Exception) {
                pending.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * 相册视频读权限（重装恢复的视频路径复活用）：已授权直接回 true；
     * 否则弹系统运行时权限窗，结果经 onRequestPermissionsResult 回填。
     */
    private fun requestVideoReadPermission(result: MethodChannel.Result) {
        val perms = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(android.Manifest.permission.READ_MEDIA_VIDEO)
        } else if (Build.VERSION.SDK_INT >= 29) {
            arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
        } else {
            // <29 走遗留外部存储（已有 WRITE 权限即读写一致），无需另请
            result.success(true)
            return
        }
        if (perms.all {
                ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
            }
        ) {
            result.success(true)
            return
        }
        pendingPermission = result
        ActivityCompat.requestPermissions(this, perms, REQ_VIDEO_READ)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == REQ_VIDEO_READ) {
            val pending = pendingPermission ?: return
            pendingPermission = null
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pending.success(granted)
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
