# example-host

管什么：

## 凭据

本目录不存明文。引用形如 `op://Private/example-host/<field>`，
需要随代码走的配置加密成 `secrets.enc.yaml`：

```bash
sops -e secrets.yaml > secrets.enc.yaml && rm -P secrets.yaml
sops secrets.enc.yaml   # 之后直接编辑
```

## 操作

## 巡检输出

写在 `_out/`。
