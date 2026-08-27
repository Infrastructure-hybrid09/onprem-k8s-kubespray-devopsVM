# 재실행 및 복구 가이드

모든 명령은 PC2 DevOps VM의 `devops` 계정에서 프로젝트 루트를 현재 디렉터리로 두고 실행한다. CP/Worker console이나 SSH shell에서 아래 프로젝트 명령을 직접 실행하지 않는다.

## 먼저 볼 것

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp
./07-troubleshooting/32-check-node.sh worker1
```

Calico:

```bash
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
kubectl -n kube-system logs -l k8s-app=calico-node --tail=200
./07-troubleshooting/32-check-node.sh worker1
```

host에서 direct API/VIP/ClusterIP가 모두 응답하지만 CoreDNS, Metrics Server
또는 일반 Pod에서 `no route to host`가 발생하면 firewalld FORWARD 경로를
확인한다.

```bash
./07-troubleshooting/38-manage-k8s-firewalld.sh status
```

기존 영구 방화벽만 켜는 원상복구와 Kubernetes 호환 모드는 서로 다르다.
임의 rich rule을 추가하지 말고
`00-docs/08-firewalld-calico-compatibility.md`의 `restore-original` 또는
`apply-k8s` action을 사용한다. 호환 적용 후에는 반드시 다음을 실행한다.

```bash
./07-troubleshooting/38-manage-k8s-firewalld.sh verify
./06-validation/24-verify-network.sh
```

인증서:

```bash
./06-validation/23-verify-cluster.sh
openssl s_client -connect 192.168.34.100:6443 </dev/null 2>/dev/null |
  openssl x509 -noout -dates -ext subjectAltName
```

API endpoint는 `https://192.168.34.100:6443`으로 고정한다. endpoint 불일치는
`14-pin-api-vip-endpoint.sh status|verify`로 확인하고, 가장 최근 적용을 되돌릴
때만 명시적 확인값과 함께 `rollback`을 실행한다. ServiceAccount issuer와
Kubernetes 내부 `neuroplan.local`은 바꾸지 않는다.

## Kubespray 재실행

동일 inventory의 `cluster.yml` 재실행은 정상적인 수렴 작업이다.

```bash
./03-kubespray/11-deploy-cluster.sh
```

상세 로그가 필요하면 중앙 script의 제한된 verbosity 입력을 사용한다. 첫 실패 task와 그 직전 원인을 먼저 해결한다.

```bash
ANSIBLE_VERBOSITY=3 ./03-kubespray/11-deploy-cluster.sh
```

Worker 한 대만 재시도:

```bash
./07-troubleshooting/34-retry-node.sh worker1
```

Control Plane/etcd는 quorum과 인증서 의존성 때문에 스크립트가 전체 inventory로 재수렴한다.

## VMware snapshot 시점

1. **Snapshot A:** 네트워크 완료 및 SSH/Python/sudo bootstrap 완료 후
2. **Snapshot B:** OS baseline과 Registry 완료, Kubespray 실행 직전
3. **Snapshot C:** Kubernetes/Calico/CoreDNS/Metrics/Gateway API 검증 완료 후
4. **Snapshot D:** NGF와 테스트 workload 전체 검증 완료 후

Snapshot은 etcd application-consistent backup을 대체하지 않는다. Cluster 생성 후에는 `33-etcd-snapshot.sh`도 실행한다.

Secret-at-rest 암호화를 사용하므로 etcd snapshot만으로는 충분하지 않다. DevOps의 `03-kubespray/inventory/mycluster/credentials/kube_encrypt_token.creds`를 snapshot/NFS/Git과 분리된 승인된 암호화 저장소에 보관한다. 복구 리허설에서는 snapshot SHA-256과 encryption credential 접근을 함께 확인하되 credential 값은 로그에 출력하지 않는다.

## etcd

상태 확인은 `23-verify-cluster.sh`, snapshot은 `33-etcd-snapshot.sh`를 사용한다. Restore는 기존 etcd 데이터를 대체하므로 이 저장소에서 자동화하지 않는다. 복제 VM에서 절차를 리허설하고 전체 팀 승인, VMware snapshot, snapshot SHA-256 확인 후 Kubespray 공식 recovery 절차로 수행한다.

## reset

`35-reset-cluster.sh`는 모든 노드의 클러스터 상태를 제거한다. 단순 배포 실패 해결용으로 먼저 사용하지 않는다. 전체 팀 승인, etcd snapshot과 VMware Snapshot B/C가 있을 때만 확인 문자열을 지정한다.

## 금지 명령

- `/etc/containerd/config.toml` 수동 덮어쓰기
- `/etc/containerd/certs.d` 별도 자동화
- Kubernetes 노드에 Docker/Podman 설치
- `podman system reset`
- Registry 데이터 디렉터리 삭제
- CP/etcd VM 두 대 동시 정지
- 승인된 `38-manage-k8s-firewalld.sh` 밖의 firewalld stop/start/rule 변경 또는 reload
