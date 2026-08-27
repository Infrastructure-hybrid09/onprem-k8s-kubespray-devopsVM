# 버전 결정 기록

> 저장소 릴리스: **v1.0.1** (2026-08-27). 이 릴리스는 문서·운영 기준 정리 패치이며 아래 플랫폼 구성요소 버전은 v1.0.0과 동일하다.

검증 기준은 Kubespray `v2.31.0`, commit `1c9add48975060f45396b34d8e022c30d7f80dab`이다.

| 구성요소 | 기획 목표 | 적용 버전 | 결정 이유 |
|---|---:|---:|---|
| Kubespray | 미지정 | v2.31.0 | release tag와 commit 고정 |
| Kubernetes | 1.35.6 | 1.35.4 | v2.31.0 checksum의 최신 1.35 patch; 1.35.6 없음 |
| containerd | 2.1.x | 2.2.3 | v2.31.0 기본 검증 조합. 2.1.7은 지원되지만 기본값 아님 |
| Calico | 3.32.x | 3.31.5 | v2.31.0 checksum에 3.32.x 없음 |
| Metrics Server | 0.8.x | 0.8.1 | v2.31.0 기본값 |
| Gateway API | 1.5.1 | 1.5.1 standard | v2.31.0 checksum과 일치 |
| NGINX Gateway Fabric | 2.6.7 | 2.6.7 | Gateway API 1.5.1, Kubernetes 1.31+ 공식 호환 |
| Helm client | 3.x | 3.18.4 | v2.31.0 checksum에 고정된 amd64 버전 |

`03-kubespray/03-verify-release.sh`가 실제 clone에서 버전과 변수 존재 여부를 다시 검사한다. 검사에 실패하면 숫자를 강제로 바꾸거나 Kubespray 소스를 patch하지 않는다.

## 공식 근거

- https://github.com/kubernetes-sigs/kubespray/releases/tag/v2.31.0
- https://raw.githubusercontent.com/kubernetes-sigs/kubespray/v2.31.0/roles/kubespray_defaults/vars/main/checksums.yml
- https://raw.githubusercontent.com/kubernetes-sigs/kubespray/v2.31.0/inventory/sample/group_vars/k8s_cluster/addons.yml
- https://github.com/nginx/nginx-gateway-fabric/blob/v2.6.7/README.md#technical-specifications
