# KVO 防护回归验证

本组测试直接编译 `JJException/Source` 的真实实现，按 podspec 将 MRC 目录使用 MRC、其他目录使用 ARC 编译，再调用系统 Foundation KVO。每个用例运行在独立进程，并设置超时，避免一例死锁阻塞整个测试。

```sh
python3 Tests/run_kvo_regression.py
python3 Tests/run_kvo_regression.py --all-guards --sanitize address
python3 Tests/run_kvo_regression.py --sanitize thread --timeout 30
```

需要 macOS、Python 3 和 Xcode 命令行工具。测试不安装依赖；编译产物置于临时目录，结束后自动删除。用 `--cases nested initial-removal` 选择用例；用 `--source-root /path/to/checkout` 将同一组测试运行在另一份库源码上。

## 覆盖范围

| 场景 | 验证内容 |
| --- | --- |
| nested | 自引用对象的嵌套 keyPath 注册、通知与移除，复现嵌套注册调用链 |
| contexts / contextless-removal | 同观察者、同属性的多个 context；精确移除、错误 context、无 context 按最近注册逐条移除 |
| invalid-removal | 未注册移除、重复注册、重复移除的防护仍有效 |
| initial-removal / initial-worker-removal | Initial 回调在当前线程或另一线程取消，不死锁，注册返回后不再收到变更 |
| concurrent-remove-during-add | 原生注册中收到取消请求，注册结束后完成清理 |
| pending-readd / failed-add-readd | 注册中取消再注册，新 options/Initial 请求保留；旧注册抛错不丢掉新请求 |
| registration-rollback | Initial 值读取抛异常后，清理实际注册和两端记录，允许重新注册 |
| pointer-identity | isEqual/hash 相同的不同观察者互不影响 |
| concurrent-churn | 8 个 pthread 对同一对象执行各 200 次注册/移除，无残留通知 |
| deallocation / self-observation / inherited-dealloc | 观察者先释放、被观察对象先释放、自观察、业务 dealloc 再次移除、无自有 dealloc 的类 |
| readd-context-order / concurrent-contextless-removal / initial-context-order | 重注册、并发移除和 Initial 嵌套注册时，多 context 的移除次序正确 |

## 实现约定

- 元数据锁只保护关系记录和发布，不覆盖原生 KVO 调用或通知回调。关系身份由对象指针、观察者指针、keyPath 和 context 决定；精确重复注册沿用防重复策略。
- 每条关系只有一个执行者调用原生 add/remove。重入或并发请求更新目标状态，由执行者在原生调用返回后继续处理；重叠请求中的非执行者不等待原生切换完成，保证执行者结束时按最终请求收敛。
- 注册中先取消再注册，会完成必要的 remove/add，保留新选项及 Initial 通知。错误回滚会清理两端记录；对象端点使用零化弱引用。
- 原生 context 移除内部再次进入无 context API 时，只对当前线程、同对象/观察者/keyPath 的调用跳过重复记账；注册及 Initial 回调不做这种跳过。
- 保留仓库已有 RAC、AVKit、AMap 特殊类兼容逻辑。通用嵌套注册测试使用普通业务对象，不依赖特殊类名单来规避死锁。

Apple 对 Initial 同步回调、context 和注册/移除配对的说明见 [Key-Value Observing Programming Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/KeyValueObserving/Articles/KVOBasics.html)。

## 本次验证边界

下载基线 `1cef457` 在 `contexts`、`initial-removal` 上断言失败，在 `concurrent-remove-during-add` 上超时；修复后的测试应全部通过。基线与 App 安装的 0.2.13 不同，不能混用版本号来判断代码是否已进入 App。

当前 Xcode 已不支持仓库 iOS 8 构建配置所需的 libarclite。验证 framework 时，可在命令行覆盖部署目标；不需要改动项目或 podspec：

```sh
xcodebuild -project JJException.xcodeproj -scheme JJExceptionCarthage \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=12.0 build
```

真机架构构建使用 `-sdk iphoneos -destination 'generic/platform=iOS'`，并换用另一 DerivedData 目录。

这些检查覆盖 Foundation 行为及 iOS framework 编译，不等同于 App 真机验证。发布依赖并恢复 App 的 KVO 防护前，仍需回归家庭留言板视频选择/预览的取消与完成、照片/视频投屏退出，以及音量监听。HiTVSDK 自身不配对的移除也应单独修复。
