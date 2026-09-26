package com.clipvault.clipvault

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
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
        const val BACKUP_NAME = "clipvault_backup.json"

        // Environment.DIRECTORY_DOWNLOADS 的字面量（"Download"）——Java 静态
        // 字段对 Kotlin const 非编译期常量，这里取字面量保持 const 语义
        const val BACKUP_RELATIVE_DIR = "Download/ClipVault"
    }

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
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // 任一原生异常都不上抛为崩溃：备份是增强能力，失败静默降级
                result.error("backup_error", e.message, null)
            }
        }
    }

    /** 查询 Downloads/ClipVault 下最新一条同名文件的 Uri（跨安装可见）。 */
    private fun queryBackupUri(): Uri? {
        val projection = arrayOf(MediaStore.Downloads._ID)
        val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
        val latest = contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            projection,
            selection,
            arrayOf(BACKUP_NAME),
            "${MediaStore.Downloads.DATE_MODIFIED} DESC",
        ) ?: return null
        latest.use { c ->
            if (!c.moveToFirst()) return null
            val id = c.getLong(0)
            return Uri.withAppendedPath(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id.toString())
        }
    }

    /** 全量重写备份（先删旧行再插入，避免多行并存与半写状态）。 */
    private fun writeBackup(json: String): Boolean {
        if (Build.VERSION.SDK_INT < 29 || json.isEmpty()) return false
        val existing = queryBackupUri()
        if (existing != null) {
            try {
                contentResolver.delete(existing, null, null)
            } catch (_: SecurityException) {
                // 旧安装遗留且 owner 未复联（签名变更等极端场景）：不删，
                // 直接另插新行，读取侧按修改时间取最新。
            }
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, BACKUP_NAME)
            put(MediaStore.Downloads.MIME_TYPE, "application/json")
            put(MediaStore.Downloads.RELATIVE_PATH, BACKUP_RELATIVE_DIR)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return false
        contentResolver.openOutputStream(uri)?.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            ?: return false
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        contentResolver.update(uri, values, null, null)
        return true
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
}
