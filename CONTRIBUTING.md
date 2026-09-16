# 贡献指南

感谢关注木照。提交前请读：

1. `flutter analyze lib/` 必须零 error
2. 行为改动必须带对应验证：引擎改动跑 `flutter test native/bench/matting_bench_test.dart`
   （黄金集指标逐位是本项目的回归标准），UI 改动跑官方截图流水线
3. **不要引入任何联网依赖**——无网络权限是产品红线，统计/上报 SDK 一律拒绝
4. 提交信息用中文一句话，说明"为什么"而不是"改了什么"

## 构建

见 README。测试素材：`test/golden/` 黄金集 + `test/dataset.json` 冻结数据集。
