---
name: run-gate
description: 执行阶段门禁的标准流程。gatekeeper 每轮验收时用，保证防作弊巡查不被跳过、结果格式一致。
---

# 门禁执行流程

法典是 `docs/ACCEPTANCE.md`。本流程只管**怎么跑**，不管判什么。

## 顺序（不可调换）

```
1. 完整性校验  → 2. 防作弊巡查 → 3. 跑脚本 → 4. 出报告
```

**先查作弊再跑脚本。** 顺序反了的话，被篡改的脚本会先给出"通过"，污染判断。

## 1. 完整性校验

```bash
sha256sum tools/gate/*.dart docs/ACCEPTANCE.md docs/RUBRIC.md > out/hashes_current.txt
diff out/hashes_prev.txt out/hashes_current.txt
```
有差异且不是你自己改的 → 直接 FAIL，报告里点名。
本轮结束后 `mv out/hashes_current.txt out/hashes_prev.txt`。

## 2. 防作弊巡查（ACCEPTANCE.md 6 条，逐条留痕）

```bash
grep -rn "skip:\|@Skip\|@Tags(\['skip'\])" test/ integration_test/
grep -rn "catch (_) {}\|catch (e) {}\|on Exception {}" lib/
ls test/golden/src/ | wc -l    # 与上一轮比较，不得减少
ls test/golden/ref/ | wc -l
```
越界检查用 git（项目已是 git 仓库，每个阶段结束由主会话打一次基线 tag）：

```bash
git diff --name-only <上一轮基线tag>..HEAD -- test/ tools/gate/ integration_test/     docs/ACCEPTANCE.md docs/RUBRIC.md
```
本轮如果有实现类 agent 在跑，上面输出**必须为空**（只有 gatekeeper 能改这些）。
仓库有未提交改动时同时看 `git status --short`。

## 3. 跑脚本

```bash
dart run tools/gate/gate_G<n>.dart --out out/gate_G<n>.json
echo "exit=$?"
```
**必须记录真实退出码。** 不许因为"大部分都过了"就人工判 PASS。

## 4. 报告

写 `out/GATE_G<n>_r<轮次>.md`，格式见 `.claude/agents/gatekeeper.md`。

必须包含：
- 结论行 `PASS` 或 `FAIL`（无第三种）
- 通过 X/Y、MANUAL 项数量（MANUAL 项必须逐条列出，不许当作通过）
- 每个失败项的 期望值 / 实测值 / 责任 agent
- 防爆弊巡查结论
- 本轮是第几轮，是否触及 3 轮上限

## 循环上限

第 3 轮仍 FAIL：写 `out/BLOCKED_G<n>.md`，宣布终止。
**不许改 `docs/ACCEPTANCE.md` 的阈值。** 那是主会话的文件，你改了就是作弊。
