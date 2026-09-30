# CI 签名钥再生成触发器

本文件被推送时触发 `.github/workflows/gen-keystore.yml`：在 runner 上
用其自带 keytool 生成 Java 原生 JKS 签名钥并上传为 artifact。

**仅在需要轮换签名钥时使用**（日常构建不依赖本文件）。产物下载后经
`CV_KEYSTORE_B64` secret 注入正式构建；密码/别名见 build.gradle.kts。
