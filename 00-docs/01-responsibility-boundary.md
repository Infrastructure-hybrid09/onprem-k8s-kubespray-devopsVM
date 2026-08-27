# 자동화 책임 경계

## 실행 계정과 SSH 경계

- PC2 DevOps VM의 로컬 운영 계정은 `devops`로 고정한다.
- CP1~3와 Worker1~3의 원격 자동화 계정은 `k8sadmin`으로 고정하고 public-key SSH와 passwordless sudo를 사용한다.
- 각 managed node의 `root` console은 최초 `k8sadmin` bootstrap에만 사용한다.
- 이후 모든 Ansible/Kubespray/add-on/검증/복구 script는 DevOps VM에서 실행한다.
- 중앙 NTP 일괄 설정은 담당자 협의 후 DevOps에서 `08-configure-all-vm-ntp.sh`만 실행한다. 이 script는 Infra/LB/DB/NFS의 기존 root SSH를 NTP 작업에만 사용하며 해당 노드를 inventory 또는 `k8sadmin` 범위에 넣지 않는다.
- Infra만 복구할 때 Infra/Network 담당자는 Infra VM에서 `07-configure-infra-ntp.sh`를 `root`로 실행한다.
- LB/DB/NFS/Infra에는 A 담당이 `k8sadmin` 또는 sudo 정책을 만들지 않는다.
- `neuroplan_k8s` private key는 DevOps VM 밖으로 복사하지 않는다.
- Kubespray inventory에는 CP1~3와 Worker1~3 정확히 6대만 포함한다. DevOps/LB/DB/NFS/Infra는 Kubespray 대상이 아니다.
- 일반 Ansible inventory에는 로컬 `devops`와 Kubernetes 6대만 포함하고, Registry play는 `devops_control`만 대상으로 한다.

## Kubespray가 담당하는 영역

- kubeadm, kubelet, kubectl 및 Kubernetes Control Plane/Worker 구성
- stacked etcd 3멤버
- containerd 설치와 `/etc/containerd` 설정
- Kubernetes repository와 패키지/바이너리
- swap 비활성화
- Kubernetes용 kernel module, sysctl, NetworkManager 예외
- Calico와 CoreDNS
- Pod CIDR, Service CIDR, Node Internal IP
- CP/Worker의 NTP/chrony client와 timezone
- SELinux 사전 정책
- Metrics Server
- Gateway API standard CRD 1.5.1
- Kubernetes Secret의 `secretbox` 기반 etcd at-rest 암호화

Kubespray 소스는 수정하지 않고 중앙 inventory/group_vars만 관리한다.

## 직접 구현하는 영역

- 최초 SSH/Python/sudo 기반을 만드는 최소 console bootstrap과 DevOps 중앙 제어 검증
- Infra upstream과 나머지 12대 VM의 Infra NTP client 설정을 백업·멱등 적용·검증하는 중앙 실행 도구
- Infra만 복구할 때 사용하는 server-only NTP 보조 도구
- DevOps와 CP/Worker에 hostname, canonical 4-Zone `/etc/hosts`, 관리 도구를 적용하는 OS baseline
- DevOps VM의 Podman 기반 Docker Distribution Registry
- DevOps VM의 Docker Hub Read-only PAT 인증과 Registry image 동기화
- DevOps VM용 Helm client
- NGINX Gateway Fabric 2.6.7
- namespace-scoped Docker Hub pull Secret, Gateway, HTTPRoute, 테스트 workload, Probe, HPA, Anti-Affinity, PDB
- 자동 검증, 진단 수집, etcd snapshot 보조 도구

## 구현하지 않는 영역

- NIC/IP/gateway/route 변경
- HAProxy/Keepalived 설정 변경
- MetalLB 또는 kube-vip
- Docker Engine
- Argo CD
- NFS/StorageClass/PV/PVC
- Monitoring/Logging 전체 스택
- 실제 Frontend/Backend 애플리케이션
- DevOps VM HA

## firewalld 경계

Calico 공식 권장 운영 상태는 CP/Worker의 firewalld 비활성화다. Network
담당자가 교육 환경에서 서비스 활성화를 요구한 경우에만 DevOps 중앙
entrypoint `38-manage-k8s-firewalld.sh`를 예외적으로 사용한다. 이 도구는
기존 `nw-*` zone/rich rule을 변경하지 않고 소유권 state가 있는 Kubernetes
호환 객체만 추가·제거한다. 그 밖의 수동 firewalld 변경과 reload는 Network
담당 영역이다. 정책 변경 후에는 반드시 CoreDNS, Pod-to-Service, VXLAN,
Metrics 및 NodePort를 다시 검사한다. 세부 절차는
`00-docs/08-firewalld-calico-compatibility.md`를 따른다.
