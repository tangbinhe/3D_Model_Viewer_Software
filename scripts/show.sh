#!/bin/bash

cd "/Users/hetangbin/AI-Avatar" || exit 1

STOPPED=0
child_pid=""
stop_all() {
    [ "$STOPPED" = 1 ] && return
    STOPPED=1
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        echo
        echo "正在停止直播主控和弹幕抓取……"
        kill -INT "$child_pid" 2>/dev/null
        wait "$child_pid"
    fi
    echo
    echo "正在停止大模型服务……"
    ./start.sh stop
    echo "全部后台服务已停止。"
}
trap 'stop_all; exit 130' INT TERM

if ! curl -sf -m 2 http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "本地大模型服务未运行，正在后台启动……"
    ./start.sh start
    for _ in $(seq 1 90); do
        curl -sf -m 2 http://127.0.0.1:8000/health > /dev/null 2>&1 && break
        sleep 1
    done
    if ! curl -sf -m 2 http://127.0.0.1:8000/health > /dev/null 2>&1; then
        echo "大模型服务启动失败，请查看 ./start.sh logs"
        exit 1
    fi
    echo "大模型服务已就绪。"
fi

if [ "$#" -gt 0 ]; then
    .venv/bin/python -u live_show.py "$1" <&0 &
else
    .venv/bin/python -u live_show.py <&0 &
fi
child_pid=$!
wait "$child_pid"
status=$?
child_pid=""
stop_all
exit "$status"
