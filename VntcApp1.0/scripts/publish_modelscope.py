"""发布 VNT 更新：版本文件全部上传和匿名下载校验后，最后切换 latest.json。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import quote

import requests

REPOSITORY = "jiangjiang419/vntc-app-updates"
BASE = f"https://modelscope.cn/models/{REPOSITORY}"


def download_url(version, name):
    return f"{BASE}/resolve/master/releases/v{version}/{quote(name)}"


def manifest_for(directory, version, source_commit, notes):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("版本必须是三段式正式版本")
    files = sorted(p for p in directory.iterdir() if p.is_file()
                   and p.name != "latest.json")
    if not files or not any(p.name == f"VNT_App_{version}_Windows_Setup.exe" for p in files):
        raise ValueError("发布目录缺少当前版本 Windows 安装包")
    assets = []
    for file in files:
        if file.stat().st_size <= 0 or file.name.startswith("."):
            raise ValueError(f"无效发布文件: {file.name}")
        assets.append({"name": file.name, "size": file.stat().st_size,
                       "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
                       "browser_download_url": download_url(version, file.name)})
    return {"schema_version": 1, "product": "vntc-app", "channel": "stable",
            "tag_name": f"v{version}", "name": f"VNT Client v{version}",
            "body": notes, "html_url": BASE, "draft": False,
            "prerelease": False, "source_commit": source_commit, "assets": assets}


def public_json(url):
    response = requests.get(url, timeout=60, headers={"Cache-Control": "no-cache"})
    response.raise_for_status()
    return response.json()


def verify_asset(asset):
    digest = hashlib.sha256()
    size = 0
    with requests.get(asset["browser_download_url"], stream=True, timeout=120) as response:
        response.raise_for_status()
        for chunk in response.iter_content(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    if size != asset["size"] or digest.hexdigest() != asset["sha256"]:
        raise ValueError(f"远端下载校验失败: {asset['name']}")
    print(f"VERIFIED {asset['name']} {size}", flush=True)


def publish(directory, version, source_commit, notes):
    from concurrent.futures import ThreadPoolExecutor
    from modelscope.hub.api import HubApi
    api = HubApi(token=os.environ.get("MODELSCOPE_TOKEN"))
    manifest = manifest_for(directory, version, source_commit, notes)
    # 同版本内容不可覆盖；失败重跑只允许复用同一组产物。
    existing = api.get_model_files(REPOSITORY, recursive=True)
    by_path = {entry["Path"]: entry for entry in existing}
    for asset in manifest["assets"]:
        remote = by_path.get(f"releases/v{version}/{asset['name']}")
        if remote and (remote.get("Sha256") != asset["sha256"] or
                       remote.get("Size") != asset["size"]):
            raise ValueError(f"拒绝覆盖已发布的不同内容: {asset['name']}")
    try:
        current = public_json(f"{BASE}/resolve/master/latest.json")
    except requests.HTTPError as error:
        if error.response.status_code != 404:
            raise
        current = None
    if current:
        current_version = tuple(map(int, current["tag_name"].lstrip("v").split(".")))
        if tuple(map(int, version.split("."))) < current_version:
            raise ValueError("拒绝回退最新版本")
    api.upload_folder(repo_id=REPOSITORY, folder_path=directory,
                      path_in_repo=f"releases/v{version}",
                      ignore_patterns=["latest.json", ".*"],
                      commit_message=f"Upload verified VNT v{version} assets", max_workers=4)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(verify_asset, manifest["assets"]))
    with tempfile.TemporaryDirectory(prefix="vnt-modelscope-") as temp:
        latest = Path(temp) / "latest.json"
        latest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        # 公开入口只在所有下载核验成功后切换。
        api.upload_file(repo_id=REPOSITORY, path_or_fileobj=latest,
                        path_in_repo="latest.json", commit_message=f"Publish VNT v{version}")
    actual = public_json(f"{BASE}/resolve/master/latest.json")
    if actual != manifest:
        raise ValueError("最新入口复核失败")
    print(f"PUBLISHED {BASE} v{version}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--notes", default="修复系统服务模式在线用户列表；后续版本通过魔搭更新。")
    args = parser.parse_args()
    publish(args.directory, args.version, args.source_commit, args.notes)


if __name__ == "__main__":
    main()
