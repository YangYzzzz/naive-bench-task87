# Microblog 手工上线说明

现行流程适用于 test-server / prod-server。工作目录是本仓库根。生产发布前在发布单上取得负责人确认。

1. 确认代码版本，运行 `scripts/build-and-copy.sh test-server`。测试与生产要分别操作。
2. 在服务器执行 `docker network inspect microblog-net >/dev/null 2>&1 || docker network create microblog-net`。
3. 在服务器检查数据卷和权限：`docker volume create microblog-data`，然后用新镜像执行 `docker run --rm --user 0 -v microblog-data:/data --entrypoint sh microblog:manual -c 'chown -R 1000:1000 /data && chmod 750 /data'`。这个步骤目前只写在文档里。
4. 执行 `scripts/backup.sh test-server`，记下输出的备份路径。
5. 把路径传入 `scripts/migrate.sh test-server <备份路径>`。备份失败或迁移失败时暂停发布。
6. 执行 `scripts/start.sh test-server`，访问 `http://test-server:8080/auth/login` 确认页面可用。
7. 测试完成后在生产服务器重复上述流程。生产服务位于 `http://prod-server:8080/auth/login`。

当前基线版本是 `microblog:baseline`。`manual` 标签曾反复被覆盖；没有可靠的自动版本历史。当前服务的数据存放在 `microblog-data` 卷中。
这些密钥字符串仅是隔离演示初态，不连接生产系统。以后需统一配置来源。故障时目前依赖人工切镜像，数据库回退需要值班人员根据备份决定。
