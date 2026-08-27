# 파일별 목적 색인

이 문서는 저장소의 모든 정적 파일을 찾기 위한 색인이다. 각 경로의 파일 자체가 생략 없는 전체 코드이며, 실제 실행 순서와 명령은 루트 `README.md`를 따른다. 실행 중 생성되는 `.venv/`, `03-kubespray/vendor/`, `logs/`, `artifacts/`와 인증서는 Git 관리 대상이 아니다. `04-registry/08-images.lock`은 image 동기화 후 생성되며, 검토한 digest 증적으로 Git에 추가할 수 있다.

## 루트

| 경로 | 목적 |
|---|---|
| `.gitignore` | private key, kubeconfig, Kubespray credentials, 인증서, vendor, venv, 로그와 실행 산출물의 Git 유입 차단 |
| `00-set-executable-permissions.sh` | 전체 디렉터리 교체 후 승인된 실행 디렉터리의 shell script만 `0755`로 초기화 |
| `README.md` | 전체 설계, 디렉터리 Tree, STEP 1~16 실행·검증·복구·인계 절차 |

## 00-docs

| 경로 | 목적 |
|---|---|
| `00-docs/00-architecture.md` | 고정 노드/IP/역할, CIDR, 트래픽 경로와 HA 범위 |
| `00-docs/01-responsibility-boundary.md` | Kubespray, 직접 구현, Network/다른 담당 영역 경계 |
| `00-docs/02-version-matrix.md` | 기획 버전과 Kubespray v2.31.0 지원 버전의 차이 및 결정 근거 |
| `00-docs/03-port-matrix.md` | source/destination/port/protocol별 통신 요구사항 |
| `00-docs/04-handoff-checklist.md` | A가 팀원에게 요구할 항목과 제공할 항목 |
| `00-docs/05-file-catalog.md` | 저장소 전체 파일의 경로와 목적 색인 |
| `00-docs/06-vscode-ssh-guide.md` | Windows 한 대에서 key 분리·ProxyJump·VS Code Remote-SSH로 모든 VM에 접속하는 절차 |
| `00-docs/07-devops-execution-policy.md` | `devops` 실행 거점, `k8sadmin` 원격 계정, key·inventory·범위 고정 정책 |
| `00-docs/08-firewalld-calico-compatibility.md` | 기존 방화벽 원상복구, lab 호환 zone/policy, 자동 안전 rollback과 전체 검증 절차 |
| `00-docs/09-api-fqdn-migration.md` | API를 DNS 비의존 VIP endpoint로 고정한 운영 결정과 검증 절차 |

## 01-bootstrap

| 경로 | 목적 |
|---|---|
| `01-bootstrap/00-devops-bootstrap.sh` | DevOps 도구·Python 3.11·SSH key·kubectl alias 준비 |
| `01-bootstrap/01-managed-node-bootstrap.sh` | 각 CP/Worker console에서 `k8sadmin`·wheel·SSH/Python·NOPASSWD sudo·public key를 멱등 설정 |
| `01-bootstrap/02-bootstrap-all-managed-nodes.sh` | 과거 명령 호환용 이름; root 변경 없이 중앙 제어 gate만 호출하는 read-only alias |
| `01-bootstrap/02-vscode-ssh-targets.conf` | PC2에서 PC5 VS Code public key를 배포할 13개 VM·계정 유형 목록 |
| `01-bootstrap/03-distribute-pc5-vscode-key.sh` | PC2 DevOps VM에서 PC5 public key를 모든 승인 VM에 멱등 배포 |
| `01-bootstrap/04-render-k8sadmin-console-command.sh` | 실제 installer와 DevOps public key를 넣은 단일 console heredoc 명령 생성 |
| `01-bootstrap/05-verify-devops-control.sh` | DevOps→여섯 managed node의 key SSH·`k8sadmin`·sudo·Python·고정 NIC 중앙 제어 게이트 |
| `01-bootstrap/06-repair-devops-public-key.sh` | 기존 private key에서 public key를 원자적으로 재생성하고 algorithm/key blob 일치를 검증 |
| `01-bootstrap/07-configure-infra-ntp.sh` | Infra 담당자가 고정 IP guard·백업·upstream/allow 설정·동기화·UDP/123/firewalld 상태를 한 번에 검증하는 NTP 준비 도구 |
| `01-bootstrap/08-configure-all-vm-ntp.sh` | DevOps에서 Infra upstream과 나머지 12대 VM의 Infra NTP client 설정을 백업·멱등 적용·검증하는 중앙 실행 도구 |

## 02-ansible

| 경로 | 목적 |
|---|---|
| `02-ansible/00-ansiblectl.sh` | `devops`·중앙 inventory·전용 key/venv를 고정한 Ansible action wrapper |
| `02-ansible/ansible.cfg` | baseline/Registry 자동화의 중앙 Ansible 동작 설정 |
| `02-ansible/inventory/hosts.yaml` | DevOps와 6개 managed node의 고정 Management/Internal/Data inventory |
| `02-ansible/inventory/group_vars/all.yml` | inventory 전체에 적용할 관리 패키지와 4-Zone 33개 `/etc/hosts` 레코드 |
| `02-ansible/templates/hosts.j2` | Management/DMZ/Internal/Data의 canonical `/etc/hosts` 전체 파일 template |
| `02-ansible/tasks/validate-host-records.yml` | 67개 FQDN/alias의 유일성과 선언 IPv4 해석을 공통 검증 |
| `02-ansible/playbooks/04-preflight.yml` | IP/default route/OS/DNS/NTP/Internet의 read-only 사전 검사 |
| `02-ansible/playbooks/05-os-baseline.yml` | hostname, hosts, 관리 패키지, sudo의 비-Kubernetes baseline |
| `02-ansible/playbooks/06-validate-baseline.yml` | hostname/IP/SSH/Python/이름 해석 baseline 검증 |

## 03-kubespray

| 경로 | 목적 |
|---|---|
| `03-kubespray/02-install-kubespray.sh` | v2.31.0 exact commit clone과 전용 Python venv 설치 |
| `03-kubespray/03-verify-release.sh` | checksum, 변수 존재 여부, 고정 버전 자동 확인 |
| `03-kubespray/ansible.cfg` | vendor의 host-key 우회 설정을 쓰지 않는 strict known_hosts·지정 key Kubespray 설정 |
| `03-kubespray/10-preflight.sh` | SSH, 노드 IP, API VIP와 Registry 경로 사전 검사 |
| `03-kubespray/11-deploy-cluster.sh` | 공식 `cluster.yml` 실행과 타임스탬프 로그 저장 |
| `03-kubespray/12-install-devops-client.sh` | 산출 admin kubeconfig를 API VIP로 검증·정규화하고 기존 설정 백업 후 DevOps에 원자적으로 설치 |
| `03-kubespray/13-migrate-api-fqdn.sh` | 보류된 API FQDN 전환 도구; 명시적 재승인 없이는 변경 action 차단 |
| `03-kubespray/14-pin-api-vip-endpoint.sh` | 기존 FQDN 잔존 설정을 백업하고 kubeadm·노드 kubeconfig를 API VIP로 순차 수렴·검증·롤백 |
| `03-kubespray/inventory/mycluster/hosts.yaml` | CP/etcd/Worker를 분리한 중앙 Kubespray inventory |
| `03-kubespray/inventory/mycluster/group_vars/all/all.yml` | 외부 API VIP, 인증서 SAN, DNS/NTP/timezone/SELinux 정책 |
| `03-kubespray/inventory/mycluster/group_vars/all/containerd.yml` | containerd 2.2.3과 공식 private Registry mirror 변수 |
| `03-kubespray/inventory/mycluster/group_vars/etcd.yml` | stacked etcd 배포·이벤트 설정 |
| `03-kubespray/inventory/mycluster/group_vars/k8s_cluster/addons.yml` | Metrics/Gateway API만 활성화하고 금지 add-on을 명시적으로 비활성화 |
| `03-kubespray/inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml` | Kubernetes 1.35.4, runtime/CNI, Pod·Service CIDR와 Secret-at-rest 암호화 설정 |
| `03-kubespray/inventory/mycluster/group_vars/k8s_cluster/k8s-net-calico.yml` | Calico 3.31.5, Internal CIDR 자동 선택, VXLAN 설정 |

## 04-registry

| 경로 | 목적 |
|---|---|
| `04-registry/06-configure-dockerhub-auth.sh` | 숨김 입력한 Read-only PAT를 저장소 밖의 0600 registry auth JSON으로 원격 검증·저장 |
| `04-registry/07-install-registry.yml` | DevOps 전용 rootful Podman Quadlet Registry 설치 |
| `04-registry/templates/07-onprem-registry.container.j2` | Internal IP bind와 persistent storage를 갖는 Quadlet |
| `04-registry/templates/07-050-onprem-registry.conf.j2` | DevOps Podman의 lab-only HTTP Registry 허용 |
| `04-registry/08-images.txt` | 필요한 upstream→private image의 명시적 매핑 목록 |
| `04-registry/08-sync-images.sh` | pull/tag/push/manifest 검증과 digest lock 생성 |
| `04-registry/09-list-images.sh` | Registry API로 repository/tag 목록 조회 |
| `04-registry/09-registryctl.sh` | start/stop/restart/status/logs/follow allowlist 제어 |
| `04-registry/09-verify-registry.sh` | service/listen/API/image 수와 Podman pull/run 검증 |

## 05-k8s-addons

| 경로 | 목적 |
|---|---|
| `05-k8s-addons/12-create-dockerhub-pull-secret.sh` | 기존 auth file로 application namespace pull Secret을 만들고 default ServiceAccount에 연결 |
| `05-k8s-addons/13-install-helm.sh` | checksum 고정 Helm 3.18.4 client 설치 |
| `05-k8s-addons/14-install-ngf.sh` | 기존 Gateway API 1.5.1 검사 후 NGF 2.6.7 설치 |
| `05-k8s-addons/14-ngf-values.yaml` | private images, controller 2개, data-plane 3개, Worker/NodePort 30443 설정 |
| `05-k8s-addons/15-namespace.yaml` | application namespace 생성 |
| `05-k8s-addons/16-test-workload.yaml` | nginx echo, Service, DNS/egress client와 Probe/리소스/배치 정책 |
| `05-k8s-addons/17-pdb.yaml` | validation workload `maxUnavailable: 1` PDB |
| `05-k8s-addons/18-hpa.yaml` | CPU 기반 3~6 replicas HPA |
| `05-k8s-addons/19-create-test-tls.sh` | Git에 key를 남기지 않는 lab TLS Secret 생성 |
| `05-k8s-addons/20-gateway.yaml` | 프로젝트에서 유일한 HTTPS Gateway |
| `05-k8s-addons/21-httproute.yaml` | 기존 Gateway의 `/validation` test route |
| `05-k8s-addons/22-apply-platform-test.sh` | namespace→workload→정책→TLS→route 순차 적용 및 상태 대기 |

## 06-validation

| 경로 | 목적 |
|---|---|
| `06-validation/23-verify-cluster.sh` | 노드/역할/CoreDNS/Calico/Metrics/API VIP/인증서/etcd 검증 |
| `06-validation/24-verify-network.sh` | Pod·Service·DNS·egress·배치·Registry CRI 경로 검증 |
| `06-validation/25-test-self-healing.sh` | Pod 삭제 후 ReplicaSet 복구와 Service 지속 검증 |
| `06-validation/26-hpa-load-job.yaml` | HPA scale-out을 위한 제한된 BusyBox 부하 Job |
| `06-validation/26-test-hpa.sh` | Metrics 선행 확인, Job 재생성, scale-out 판정과 실패 로그 |
| `06-validation/27-verify-pdb.sh` | PDB health와 voluntary disruption allowance 검증 |
| `06-validation/28-verify-ngf.sh` | CRD/NGF/Gateway/Route/NodePort/Service VIP 전체 경로 검증 |
| `06-validation/29-verify-ha-readonly.sh` | API·서비스 연속 요청과 etcd 상태의 비파괴 HA 기준선 검사 |
| `06-validation/30-run-all.sh` | 모든 검증의 PASS/FAIL 집계 실행기 |

## 07-troubleshooting

| 경로 | 목적 |
|---|---|
| `07-troubleshooting/31-collect-diagnostics.sh` | Secret 내용을 제외한 클러스터 진단 증적 수집 |
| `07-troubleshooting/32-check-node.sh` | 허용된 노드 하나의 systemd/network/runtime 상태 조회 |
| `07-troubleshooting/33-etcd-snapshot.sh` | CP1 snapshot 생성·상태 확인·SHA-256 검증·DevOps fetch |
| `07-troubleshooting/34-retry-node.sh` | Worker 제한 재시도 또는 CP/etcd 전체 inventory 안전 재수렴 |
| `07-troubleshooting/35-reset-cluster.sh` | 명시적 확인 문자열로 보호한 전체 Kubespray reset |
| `07-troubleshooting/36-recovery.md` | 로그, Calico, 인증서, snapshot, 재실행과 금지 명령 안내 |
| `07-troubleshooting/37-cleanup-validation.sh` | ownership label이 있는 검증 리소스만 정리 |
| `07-troubleshooting/38-manage-k8s-firewalld.sh` | 여섯 노드의 원본 firewalld 활성화 또는 소유권이 분리된 Calico lab 호환 정책 적용·검증·rollback |

## nodes

| 경로 | 목적 |
|---|---|
| `nodes/cp1/00-node-facts.md` | CP1 역할/IP/물리 배치/금지사항 기준 정보 |
| `nodes/cp2/00-node-facts.md` | CP2 역할/IP/물리 배치/금지사항 기준 정보 |
| `nodes/cp3/00-node-facts.md` | CP3 역할/IP/물리 배치/금지사항 기준 정보 |
| `nodes/worker1/00-node-facts.md` | Worker1 역할/IP/물리 배치/금지사항 기준 정보 |
| `nodes/worker2/00-node-facts.md` | Worker2 역할/IP/물리 배치/금지사항 기준 정보 |
| `nodes/worker3/00-node-facts.md` | Worker3 역할/IP/물리 배치/금지사항 기준 정보 |
