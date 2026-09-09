<!-- new-task-review -->
review_actor=ACTOR_ID
claim_actor=CLAIM_ACTOR_ID
Self-review=no

## Review

| 项 | 值 |
| --- | --- |
| Verdict | 通过 |
| reviewed HEAD | `FULL_SHA` |
| 范围 | 授权范围路径 |
| Squash-Title | `type(scope): 描述` |
| Issue | owner/repo#N |
| Contract | `blob-sha` |
| review_actor | `ACTOR_ID` |
| claim_actor | `CLAIM_ACTOR_ID` |
| Self-review | `no` |

### 通过理由

（不通过时改为「### 阻断项」，Squash-Title 为 `（无）`。）

### 证据

```
命令与结果
```

### 最小充分审查

- 审查代码与调用点：实际看过的代码
- 复用证据：Checkpoint 里可复用的验证
- 新增验证：本次新跑的定向检查
- 覆盖范围：实际审查/验证了什么（不要复制授权范围）
- 未执行的大范围验证：没跑什么
- 剩余风险：未知/未验证/失败/不适用/有依据的风险接受，必须分开写

### Contract 对照

- R1：满足。实现位置与证据。
- A1：通过。证据。
