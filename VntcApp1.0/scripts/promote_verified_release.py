"""复用已通过四平台构建的产物，只重试发布阶段。"""
import hashlib,json,os,subprocess,tempfile,shutil
from pathlib import Path
from publish_modelscope import publish,REPOSITORY,BASE,public_json
REPO='luojiang419/VNTC2.0-APP'
def gh(*args):
    return subprocess.check_output(['gh',*args],encoding='utf-8')
def api(path): return json.loads(gh('api',f'repos/{REPO}/'+path))
def main():
    run_id=os.environ['SOURCE_RUN_ID']
    run=api(f'actions/runs/{run_id}')
    assert run['path']=='.github/workflows/build.yml' and run['status']=='completed'
    source=run['head_sha']
    jobs=api(f'actions/runs/{run_id}/jobs?per_page=100')['jobs']
    required={'客户端静态分析与测试','校验发布签名策略','Windows 客户端安装版','macOS 客户端','Android 客户端','Android RustDesk 16KB 原生库','Linux WebUI 客户端'}
    assert all(any(j['name']==name and j['conclusion']=='success' for j in jobs) for name in required)
    version='4.8.42';tag='v'+version
    with tempfile.TemporaryDirectory() as temp:
        root=Path(temp);download=root/'artifacts';stage=root/'assets';stage.mkdir()
        gh('run','download',run_id,'--repo',REPO,'--dir',str(download))
        for file in download.rglob('*'):
            if file.is_file():
                target=stage/file.name
                assert not target.exists(),file.name
                shutil.copy2(file,target)
        files=sorted(stage.iterdir());assert len(files)==16,len(files)
        (stage/'SHA256SUMS.txt').write_bytes(('\n'.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name for f in files)+'\n').encode())
        # ModelScope 副本单独规范化，GitHub 保留原 CI 字节。
        publish(stage,version,source,'修复在线用户列表及服务升级；本版本起后续仅使用魔搭更新。')
        manifest={'version':version,'tag':tag,'release_scope':'client','signing_mode':'compatible','release_url':f'https://github.com/{REPO}/releases/tag/{tag}',
          'assets':[{'name':f.name,'size':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'download_url':f'https://github.com/{REPO}/releases/download/{tag}/{f.name}'} for f in files]}
        (stage/'latest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
        notes=root/'notes.md';notes.write_text('这是最后一个 GitHub 过渡版本。修复系统服务在线用户不可见及安装器服务路径问题。安装后，后续更新仅使用魔搭：'+BASE,encoding='utf-8')
        existing=subprocess.run(['gh','release','view',tag,'--repo',REPO],capture_output=True)
        if existing.returncode:
            gh('release','create',tag,'--repo',REPO,'--target',source,'--title','VNT Client '+tag,'--draft','--notes-file',str(notes))
        release=api('releases/tags/'+tag)
        assert release['draft'] and release['target_commitish']==source
        gh('release','upload',tag,'--repo',REPO,*[str(f) for f in stage.iterdir()],'--clobber')
        release=api('releases/tags/'+tag);assets={a['name']:a for a in release['assets']}
        assert set(assets)=={f.name for f in stage.iterdir()}
        for f in stage.iterdir():
            a=assets[f.name];assert a['state']=='uploaded' and a['size']==f.stat().st_size
            assert a['digest']=='sha256:'+hashlib.sha256(f.read_bytes()).hexdigest()
        gh('release','edit',tag,'--repo',REPO,'--draft=false','--latest')
        result=api('releases/latest');assert result['tag_name']==tag and not result['draft'] and not result['prerelease']
        ref=api('git/ref/tags/'+tag);assert ref['object']['sha']==source
        assert public_json(BASE+'/resolve/master/latest.json')['source_commit']==source
        print('PROMOTION_VERIFIED',tag,source,len(assets),flush=True)
if __name__=='__main__':main()
