# Kubernetes API endpoint 운영 결정

## 최종 결정

Kubernetes API의 유일한 canonical endpoint는 다음 고정 VIP다.

```text
https://192.168.34.100:6443
```

`api.k8s.neuroplan.local`과 `api.k8s.nplan.local`은 운영 API endpoint로
사용하지 않는다. Infra BIND에 두 이름의 레코드가 없어도 정상 운영돼야 한다.
과거 이름을 `/etc/hosts`에 남기는 경우에도 전환 작업의 롤백 호환 경로일 뿐
상시 의존성은 아니다.

| 항목 | 고정할 값 |
|---|---|
| Kubernetes API endpoint | `https://192.168.34.100:6443` |
| Kubernetes cluster domain | `neuroplan.local` |
| ServiceAccount issuer | `https://kubernetes.default.svc.neuroplan.local` |
| Infra BIND domain | `nplan.local` |
| Pod NodeLocal DNS | `169.254.25.10` |

API endpoint를 VIP IP로 바꾸는 작업은 Kubernetes Service DNS domain을 바꾸는
작업이 아니다. CoreDNS, NodeLocal DNS, kubelet `clusterDomain`, ServiceAccount
issuer와 `*.svc.neuroplan.local`은 그대로 유지한다.

## Kubespray 원본

```yaml
loadbalancer_apiserver:
  address: 192.168.34.100
  port: 6443
loadbalancer_apiserver_localhost: false

supplementary_addresses_in_ssl_keys:
  - 192.168.34.100
```

`apiserver_loadbalancer_domain_name`은 선언하지 않는다. Kubespray v2.31.0은
이 경우 `loadbalancer_apiserver.address`를 API endpoint로 사용한다.

## 기존 클러스터 수렴

```bash
cd ~/onprem-k8s
source .venv/bin/activate
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"

./03-kubespray/14-pin-api-vip-endpoint.sh status
CONFIRM_API_VIP_ENDPOINT=apply \
  ./03-kubespray/14-pin-api-vip-endpoint.sh apply
./03-kubespray/14-pin-api-vip-endpoint.sh verify
```

`apply`는 다음 순서로 동작한다.

1. API, 노드 6대, API Server 3대, etcd 3멤버 상태 확인
2. kubeadm ConfigMap, DevOps kubeconfig와 각 노드 설정 전체 백업
3. CP1~3의 `kubeadm-config.yaml`을 VIP로 정규화하고 `kubeadm config validate`
4. CP1에서 검증된 ClusterConfiguration 업로드
5. 노드별 kubeconfig를 VIP로 바꾸고 필요한 kubelet만 한 대씩 재시작
6. 각 노드 Lease 갱신과 Ready를 확인한 뒤 다음 노드 진행
7. ConfigMap, 모든 kubeconfig, API 인증서 IP SAN과 전체 상태 검증

실행 중 오류가 나면 다음 노드로 진행하지 않는다. 최근 작업을 되돌려야 할 때:

```bash
CONFIRM_API_VIP_ENDPOINT=rollback \
  ./03-kubespray/14-pin-api-vip-endpoint.sh rollback
```

## 금지사항

- `clusterDomain: neuroplan.local`을 `nplan.local`로 일괄 치환하지 않는다.
- API 인증서를 수동 재발급하거나 static Pod manifest를 직접 편집하지 않는다.
- `kubeadm-config` ConfigMap만 단독 편집하고 노드 파일을 방치하지 않는다.
- `13-migrate-api-fqdn.sh`의 FQDN 변경 action을 실행하지 않는다.
