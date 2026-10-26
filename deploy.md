# Microblog 手工上线说明

现行流程适用于 test-server / prod-server。工作目录是本仓库根，生产发布前在发布单上取得负责人确认。
两台服务器通过 SSH 操作，使用 Python 虚拟环境和 Gunicorn 进程部署，不使用 Docker 或 systemd。
依赖已装在 /opt/task87-venv，更新代码不必重新下载现有依赖。

1. 确认并提交代码版本，运行 `scripts/build-and-copy.sh test-server`。测试与生产要分别操作。
2. 在服务器执行 `install -d -o app -g app -m 750 /srv/microblog/data /srv/microblog/logs /srv/microblog/run`，并执行 `chown -R app:app /srv/microblog/releases/manual`。这个准备权限的步骤目前只写在文档里。
3. 执行 `scripts/backup.sh test-server`，记下输出的数据库备份路径。
4. 把路径传入 `scripts/migrate.sh test-server <备份路径>`。备份失败或迁移失败时暂停发布。
5. 执行 `scripts/start.sh test-server`，访问 `http://test-server:8080/auth/login` 确认页面可用。
6. 测试完成并获得批准后，在生产服务器重复上述流程；生产地址是 `http://prod-server:8080/auth/login`。

当前初始服务在 `/srv/microblog/releases/baseline`，`/srv/microblog/current` 指向当前版本。
数据库位于 `/srv/microblog/data/app.db`，备份位于 `/srv/microblog/backups/`。
手工发布一直覆盖 `manual` 目录，没有可靠的版本归档和自动回滚。
脚本中的演示密钥仅用于这两台隔离测试服务器，配置来源尚未统一。故障时目前由值班人员手工恢复程序，数据库是否恢复由其根据备份决定。
仓库中的 Dockerfile/boot.sh 是上游保留的容器部署材料，不属于当前服务器的部署方式。
