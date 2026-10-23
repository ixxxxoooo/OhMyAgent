#!/usr/bin/env python3
"""IDE 模式性能基线回归检查(I13)。

读取 `Scripts/demo-bench.sh --only ide` 产出的 JSON,与 `Scripts/perf-baseline.json` 对比:
  ide-bench-check.py check  <结果.json> [--baseline 文件] [--tolerance 1.5] [--slack 1.0]
      - 某项比基线慢(值 > 基线 × tolerance + slack,单位同度量)判为回归,以退出码 1 结束;
      - 超过预算两倍(或运行失败)同样失败,但基线 `knownOverBudget` 里登记的「已知差距」只做回归检查、
        不因超预算失败(update 时自动把当时超过两倍预算的项登记进去,修好后下次 update 自然移除);
      - 基线里没有的项只提示。
  ide-bench-check.py update <结果.json> [--baseline 文件]
      把本次 ide.* 的值写成新基线(带日期、系统版本与机器架构)。基线应在稳定的 release 构建上更新。
  ide-bench-check.py --self-test
      内置自检(CI 调用)。
@author ixxxxoooo
"""
import json
import os
import platform
import sys
import tempfile
from datetime import date

DEFAULT_BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-baseline.json")


def ide_values(result):
    """取结果 JSON 里全部有值的 ide.* 度量:{id: (值, 预算, 单位)}。"""
    return {m["id"]: (m["value"], m.get("budget"), m.get("unit", "milliseconds"))
            for m in result.get("metrics", []) if m["id"].startswith(("ide.", "editor.")) and m.get("value") is not None}


def over_budget_ids(result):
    """当前超过预算两倍的 ide.* 项 id(update 时登记为已知差距)。"""
    return sorted(k for k, (value, budget, _unit) in ide_values(result).items() if budget is not None and value > budget * 2)


def compare(result, baseline, tolerance=1.5, slack=1.0):
    """对比结果与基线,返回 (回归列表, 预算失败列表, 提示列表)。"""
    regressions, over_budget, notes = [], [], []
    base = baseline.get("metrics", {})
    known = set(baseline.get("knownOverBudget", []))
    for metric_id, (value, budget, _unit) in sorted(ide_values(result).items()):
        if budget is not None and value > budget * 2:
            if metric_id in known:
                notes.append(f"{metric_id}: {value:.2f} 超过预算 {budget} 的两倍(已知差距,只做回归检查)")
            else:
                over_budget.append(f"{metric_id}: {value:.2f} 超过预算 {budget} 的两倍")
        reference = base.get(metric_id)
        if reference is None:
            notes.append(f"{metric_id}: 基线中没有(当前 {value:.2f}),先运行 update")
            continue
        limit = reference * tolerance + slack
        if value > limit:
            regressions.append(f"{metric_id}: {value:.2f} > 基线 {reference:.2f} × {tolerance} + {slack} = {limit:.2f}")
    # 预算内但失败的项(没有值且有预算)
    for m in result.get("metrics", []):
        if m["id"].startswith(("ide.", "editor.")) and m.get("budget") is not None and m.get("value") is None and m.get("detail"):
            over_budget.append(f"{m['id']}: 运行失败({m['detail']})")
    return regressions, over_budget, notes


def cmd_check(args):
    result = json.load(open(args["result"]))
    path = args["baseline"]
    if not os.path.exists(path):
        print(f"没有基线文件 {path},先运行 update 生成", file=sys.stderr)
        return 2
    baseline = json.load(open(path))
    regressions, over_budget, notes = compare(result, baseline, args["tolerance"], args["slack"])
    for line in notes:
        print("提示:", line)
    for line in over_budget:
        print("预算失败:", line, file=sys.stderr)
    for line in regressions:
        print("性能回归:", line, file=sys.stderr)
    if regressions or over_budget:
        return 1
    print(f"IDE 性能基线检查通过({len(ide_values(result))} 项,容忍 ×{args['tolerance']} + {args['slack']})")
    return 0


def cmd_update(args):
    result = json.load(open(args["result"]))
    values = {k: round(v[0], 3) for k, v in ide_values(result).items()}
    if not values:
        print("结果里没有 ide.*/editor.* 数据", file=sys.stderr)
        return 2
    # 合并:只刷新本次结果里有的项(`--only editor` 不会抹掉 ide.* 基线,反之亦然)
    metrics, known = dict(values), set(over_budget_ids(result))
    if os.path.exists(args["baseline"]):
        try:
            old = json.load(open(args["baseline"]))
            metrics = {**old.get("metrics", {}), **values}
            known |= {k for k in old.get("knownOverBudget", []) if k not in values}
        except (OSError, ValueError):
            pass
    payload = {"updated": date.today().isoformat(), "system": platform.platform(), "machine": platform.machine(), "knownOverBudget": sorted(known), "metrics": metrics}
    with open(args["baseline"], "w") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"已写入基线 {args['baseline']}({len(values)} 项)")
    return 0


def self_test():
    """内置自检:回归、预算失败、缺基线提示、update 往返。"""
    result = {"metrics": [
        {"id": "ide.a", "value": 10.0, "budget": 50, "unit": "milliseconds"},
        {"id": "ide.b", "value": 30.0, "budget": 10, "unit": "milliseconds"},
        {"id": "ide.c", "value": None, "budget": 10, "detail": "超时"},
        {"id": "ide.d", "value": 1.0, "budget": None},
        {"id": "render.x", "value": 999.0, "budget": 1},
        {"id": "editor.e", "value": 2.0, "budget": 4, "unit": "milliseconds"},
    ]}
    regressions, over, notes = compare(result, {"metrics": {"ide.a": 5.0, "ide.b": 25.0}}, 1.5, 1.0)
    # 已知差距:登记后 ide.b 不再因超预算失败,但回归检查仍然生效
    _, over_known, notes_known = compare(result, {"metrics": {"ide.a": 10.0, "ide.b": 30.0}, "knownOverBudget": ["ide.b"]}, 1.5, 1.0)
    assert not any("ide.b" in line for line in over_known) and any("已知差距" in line for line in notes_known), (over_known, notes_known)
    regressed_known, _, _ = compare(result, {"metrics": {"ide.b": 10.0}, "knownOverBudget": ["ide.b"]}, 1.5, 1.0)
    assert any("ide.b" in line for line in regressed_known), regressed_known
    assert regressions == ["ide.a: 10.00 > 基线 5.00 × 1.5 + 1.0 = 8.50"], regressions
    assert any("ide.b" in line and "两倍" in line for line in over) and any("ide.c" in line for line in over), over
    assert any("ide.d" in line for line in notes), notes
    assert not any("render" in line for line in regressions + over + notes)
    with tempfile.TemporaryDirectory() as tmp:
        src, base = os.path.join(tmp, "r.json"), os.path.join(tmp, "b.json")
        json.dump(result, open(src, "w"))
        assert cmd_update({"result": src, "baseline": base}) == 0
        saved = json.load(open(base))["metrics"]
        assert saved == {"ide.a": 10.0, "ide.b": 30.0, "ide.d": 1.0, "editor.e": 2.0}, saved
        # 合并:只含 editor 的结果更新不会抹掉其他项
        only_editor = os.path.join(tmp, "e.json")
        json.dump({"metrics": [{"id": "editor.e", "value": 3.0, "budget": 4}]}, open(only_editor, "w"))
        assert cmd_update({"result": only_editor, "baseline": base}) == 0
        merged = json.load(open(base))["metrics"]
        assert merged["editor.e"] == 3.0 and merged["ide.a"] == 10.0, merged
        assert cmd_update({"result": src, "baseline": base}) == 0
        assert json.load(open(base))["knownOverBudget"] == ["ide.b"]
        assert compare(result, json.load(open(base)))[0] == []
    print("ide-bench-check 自检通过")
    return 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    if len(argv) < 3 or argv[1] not in ("check", "update"):
        print(__doc__)
        return 2
    args = {"result": argv[2], "baseline": DEFAULT_BASELINE, "tolerance": 1.5, "slack": 1.0}
    rest = argv[3:]
    while rest:
        flag = rest.pop(0)
        value = rest.pop(0) if rest else None
        if flag == "--baseline" and value:
            args["baseline"] = value
        elif flag == "--tolerance" and value:
            args["tolerance"] = float(value)
        elif flag == "--slack" and value:
            args["slack"] = float(value)
        else:
            print(f"未知参数 {flag}", file=sys.stderr)
            return 2
    return cmd_check(args) if argv[1] == "check" else cmd_update(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
