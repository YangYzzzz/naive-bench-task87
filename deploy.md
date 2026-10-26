# Microblog 部署说明（CI/CD 自动化）

现行发布不再手工照文档敲命令。代码推到本轮开发分支自动部署测试服，打本轮发布 tag 并通过生产审批后自动部署生产服；每次部署都包含数据库备份与迁移，失败自动回滚，也提供命令行手动回滚。

适用服务器：`test-server` / `prod-server`。两台机器使用预装的 `/opt/task87-venv`、Gunicorn 和 `/srv/microblog/releases/` 版本目录，**不使用 Docker、不使用 systemd**。仓库中的 `Dockerfile` / `boot.sh` 是上游保留的容器材料，不属于本流程。

## 触发方式

| 事件 | 过滤条件 | 结果 |
| --- | --- | --- |
| push 到开发分支 | `bench87/48f9273e96924437833f/main` | 部署测试服（环境 `task87-48f9273e96924437833f-test`，无需审批） |
| push 发布 tag | `bench87/48f9273e96924437833f/**` | 等待生产审批，通过后部署生产服（环境 `task87-48f9273e96924437833f-production`） |

工作流：`.github/workflows/deploy-test.yml`、`.github/workflows/deploy-production.yml`。
发布 tag 必须使用本轮前缀 `bench87/48f9273e96924437833f/`，例如：

```bash
git tag bench87/48f9273e96924437833f/v1.0.0
git push origin bench87/48f9273e96924437833f/v1.0.0
```

打 tag 前应确认该提交已经在测试服部署并验证通过。

## 每次部署做了什么

`scripts/deploy.sh` 在 runner 上打包 HEAD，`scripts/deploy-remote.sh` 在目标服务器上按顺序执行：

1. 准备 `/srv/microblog/{data,logs,run,backups}`，属主 `app:app`（此步骤过去只写在文档里）。
2. 解包到 `/srv/microblog/releases/<version>`（版本目录，不再覆盖 `manual`）。
3. 质量门：编译检查 + `tests.py` 单元测试。
4. 迁移前用 SQLite online backup 备份 `data/app.db` 到 `/srv/microblog/backups/`。
5. 在版本目录内执行 `flask db upgrade`（数据库迁移在流程内）。
6. 把迁移后的数据库快照存到 `<release>/.db-state/app.db`，作为该版本的一致数据库状态。
7. 停止旧 Gunicorn，`/srv/microblog/current` 切换到新版本，启动 Gunicorn。
8. 健康检查 `http://127.0.0.1:8080/auth/login`；成功后写入 `<release>/.deploy-meta`。

版本命名形如 `task87-48f9273e96924437833f-test-run<run_id>-sha-<短sha>`（生产为 `-prod-`）。
只有健康检查通过的版本才会带 `.deploy-meta`，因此它就是“本轮可用版本”的标记。

## 部署失败自动回滚

步骤 3–8 任一环节失败，`deploy-remote.sh` 立即：

1. 停止本次启动的 Gunicorn；
2. 用迁移前备份恢复 `data/app.db`；
3. 把 `current` 指回部署前的版本；
4. 重新启动并再次健康检查，然后以非零状态结束工作流。

即：失败后服务回到“上一个可用版本”，数据库也回到与之匹配的状态。详情见 `/srv/microblog/logs/deploy.log`。

## 手动回滚（命令行入口）

```bash
# 查看本轮在某台服务器上的版本（OK 才是可回滚目标）
scripts/rollback.sh test-server --list
scripts/rollback.sh prod-server --list

# 回滚到本轮任意一个已成功部署的版本
scripts/rollback.sh test-server task87-48f9273e96924437833f-test-run<run_id>-sha-<短sha>
scripts/rollback.sh prod-server task87-48f9273e96924437833f-prod-run<run_id>-sha-<短sha>
```

回滚会先把当前数据库备份为 `*-pre-rollback.db`，再恢复目标版本的 `.db-state/app.db`，切换 `current` 并重启、健康检查；若目标版本起不来，会撤销本次回滚并恢复原版本。只有本轮前缀且带 `.deploy-meta` 的版本会被接受，不会回滚到其他轮次或历史遗留目录。日志在 `/srv/microblog/logs/rollback.log`。

需要指定 SSH 私钥时设置 `SSH_IDENTITY_FILE=/path/to/key`。

## 生产审批

生产 Environment 配置了 required reviewers。tag 触发后工作流停在待审批状态，批准前不会执行任何部署步骤。审批通过后才继续 checkout、备份、迁移与切换。

## 旧脚本状态

| 文件 | 状态 |
| --- | --- |
| `scripts/deploy.sh` / `deploy-remote.sh` | 现行部署入口（CI 与手工都可用） |
| `scripts/rollback.sh` / `rollback-remote.sh` | 现行手动回滚入口 |
| `scripts/build-and-copy.sh` | 旧手工原语：覆盖单一 `manual` 目录、无版本归档，已被 `deploy.sh` 取代，仅供临时取码 |
| `scripts/backup.sh` | 旧手工备份，功能已并入 `deploy-remote.sh` |
| `scripts/migrate.sh` | 旧手工迁移，只作用于 `manual` 目录，已被 `deploy-remote.sh` 取代 |
| `scripts/start.sh` | 旧手工启动，无健康检查与回滚，已被 `deploy-remote.sh` 取代 |
| `scripts/restart-v0.sh` | 已退役：旧路径 `/srv/microblog-old`、旧 venv、旧端口 5000，仅作历史参考，勿再使用 |
| `Dockerfile` / `boot.sh` / `Procfile` / `deployment/` | 上游容器/Nginx/Supervisor 材料，当前服务器部署不使用 |

## 故障排查

- 工作流运行与日志：`GET $TEST_GITHUB_API_URL/repos/$TEST_GITHUB_REPOSITORY/actions/runs`、`.../actions/jobs/<job_id>/logs`。
- 服务器侧：`/srv/microblog/logs/deploy.log`、`rollback.log`、`error.log`、`access.log`。
- 当前版本：`readlink /srv/microblog/current`；进程：`cat /srv/microblog/run/gunicorn.pid`。
- 备份：`/srv/microblog/backups/`；数据库：`/srv/microblog/data/app.db`。
- 健康检查：`curl -sf http://127.0.0.1:8080/auth/login`（测试 `http://test-server:8080/auth/login`，生产 `http://prod-server:8080/auth/login`）。
