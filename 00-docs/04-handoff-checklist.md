# 협업 및 인계 체크리스트

## A가 요구할 것

### Network/HA 담당

- [ ] API VIP `192.168.34.100:6443`와 CP `.34.31~33:6443` backend health
- [ ] Service VIP `192.168.24.100:443`와 Worker `.34.41~43:30443` backend health
- [ ] 모든 kubeconfig와 kubeadm `controlPlaneEndpoint`가 `192.168.34.100:6443` 사용
- [ ] `app.nplan.local -> 192.168.24.100`
- [ ] Kubernetes 내부 Service DNS `*.svc.neuroplan.local`은 Infra BIND `nplan.local`과 분리 유지
- [ ] TCP 22/2379-2380/5000/6443/10250/30443 및 UDP 4789 경로
- [ ] Infra NTP `192.168.14.62:123/UDP` listener, `allow 192.168.14.0/24`, upstream `^*`, `Leap status: Normal` 및 CP1 `chronyd -Q` 성공 증거
- [ ] firewalld 정책 변경 시각과 적용 증거
- [ ] firewalld 사용 여부 결정: Calico 공식 권장 비활성화 또는 승인된 lab 호환 모드
- [ ] 호환 모드이면 물리/VMware 구간의 Pod CIDR `10.244.0.0/16` source spoofing 차단

### DevOps/CI-CD 담당

- [ ] 프로젝트 Git 원격 저장소와 branch/protection 정책
- [ ] `neuroplan_k8s` private key를 DevOps 밖으로 복사하지 않으며 분실 시 새 key 발급·여섯 public key 교체로 회전하는 정책
- [ ] 프로젝트 실행 거점 `devops@192.168.14.21`과 CP/Worker 원격 사용자 `k8sadmin` 고정 합의
- [ ] Private Registry 보존 용량과 image retention
- [ ] Docker Hub Read-only PAT의 소유자·만료일·회전/폐기 일정; PAT와 auth JSON은 팀 채팅·Git·백업으로 공유하지 않음
- [ ] application/GitOps 저장소와 image tag 정책
- [ ] Argo CD 구축 후 사용할 최소 RBAC 요구사항

### Application 담당

- [ ] 신규 경로는 기존 `application/neuroplan-gateway`에 HTTPRoute로 연결하며 두 번째 Gateway를 만들지 않음
- [ ] namespace, Service 이름/포트, hostname
- [ ] readiness/liveness/startup endpoint
- [ ] requests/limits와 HPA 값
- [ ] Replica/Anti-Affinity/PDB 요구사항
- [ ] 운영 TLS 인증서 Secret 전달 방식

### Data/Storage/Monitoring 담당

- [ ] MaxScale endpoint `192.168.44.21:4006`
- [ ] NFS `/backup/etcd` export와 권한
- [ ] StorageClass/PV/PVC 설계
- [ ] Prometheus/Grafana/Loki의 PV·retention·RBAC 요구사항

## A가 제공할 것

- [ ] `05-verify-devops-control.sh`의 여섯 노드 PASS 결과와 inventory 경로
- [ ] 확정 노드/IP/role 및 실제 설치 버전
- [ ] API endpoint와 제한된 kubeconfig/RBAC
- [ ] API 인증서 IP SAN `192.168.34.100`과 VIP 기반 kubeconfig 유지
- [ ] Pod/Service CIDR와 Registry endpoint
- [ ] Docker Hub PAT 대신 사설 Registry image 경로와 digest lock만 제공
- [ ] GatewayClass/Gateway/HTTPRoute/NodePort 정보
- [ ] `30443`은 cluster-wide 단일 NodePort이므로 Gateway를 하나만 유지해야 한다는 변경 규칙
- [ ] Metrics Server/HPA 검증 결과
- [ ] etcd snapshot 위치·SHA-256·복구 리허설 결과
- [ ] snapshot과 분리 보관한 `kube_encrypt_token.creds`의 복구 책임자·접근권한·복구 리허설 결과(credential 값 자체는 공유하지 않음)
- [ ] 장애 시연 순서, 성공 조건, 원복 방법
- [ ] firewalld `status/verify` 로그, 노드별 backup 위치와 호환 객체 rollback 방법
- [ ] 변경 금지 시간과 kubeconfig/token 폐기 일정
