---
# Namespace for CSI driver
apiVersion: v1
kind: Namespace
metadata:
  name: truenas-csi
---
# ServiceAccount for the CSI driver
apiVersion: v1
kind: ServiceAccount
metadata:
  name: truenas-csi-controller-sa
  namespace: truenas-csi
---
# ServiceAccount for node plugin
apiVersion: v1
kind: ServiceAccount
metadata:
  name: truenas-csi-node-sa
  namespace: truenas-csi
---
# ClusterRole for CSI controller
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: truenas-csi-controller-role
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["csinodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["list", "watch", "create", "update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments/status"]
    verbs: ["patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "watch", "list", "delete", "update", "create"]
---
# ClusterRoleBinding for CSI controller
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: truenas-csi-controller-binding
subjects:
  - kind: ServiceAccount
    name: truenas-csi-controller-sa
    namespace: truenas-csi
roleRef:
  kind: ClusterRole
  name: truenas-csi-controller-role
  apiGroup: rbac.authorization.k8s.io
---
# ClusterRole for CSI node
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: truenas-csi-node-role
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch"]
---
# ClusterRoleBinding for CSI node
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: truenas-csi-node-binding
subjects:
  - kind: ServiceAccount
    name: truenas-csi-node-sa
    namespace: truenas-csi
roleRef:
  kind: ClusterRole
  name: truenas-csi-node-role
  apiGroup: rbac.authorization.k8s.io
---
# CSI Driver object
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: csi.truenas.io
spec:
  attachRequired: true
  podInfoOnMount: true
  fsGroupPolicy: File
  volumeLifecycleModes:
    - Persistent
    - Ephemeral
---
# ConfigMap for driver configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: truenas-csi-config
  namespace: truenas-csi
data:
  truenasURL: "${truenas_url}"
  truenasInsecure: "${truenas_insecure}"
  defaultPool: "${default_pool}"
  nfsServer: "${nfs_server}"
  iscsiPortal: "${iscsi_portal}"
  iscsiIQNBase: "iqn.2000-01.io.truenas"
---
# Controller Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: truenas-csi-controller
  namespace: truenas-csi
spec:
  replicas: 1
  selector:
    matchLabels:
      app: truenas-csi-controller
  template:
    metadata:
      labels:
        app: truenas-csi-controller
    spec:
      serviceAccountName: truenas-csi-controller-sa
${image_pull_secrets}
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/etcd
          operator: Exists
          effect: NoExecute
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: csi-controller
          image: ${truenas_csi_image}
          imagePullPolicy: IfNotPresent
          args:
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--node-id=$(NODE_ID)"
            - "--v=4"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: TRUENAS_URL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: truenasURL
            - name: TRUENAS_API_KEY
              valueFrom:
                secretKeyRef:
                  name: truenas-api-credentials
                  key: api-key
            - name: TRUENAS_DEFAULT_POOL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: defaultPool
            - name: TRUENAS_NFS_SERVER
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: nfsServer
            - name: TRUENAS_ISCSI_PORTAL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: iscsiPortal
            - name: TRUENAS_ISCSI_IQN_BASE
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: iscsiIQNBase
                  optional: true
            - name: TRUENAS_INSECURE_SKIP_VERIFY
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: truenasInsecure
                  optional: true
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9808
            initialDelaySeconds: 10
            timeoutSeconds: 3
            periodSeconds: 10
            failureThreshold: 5
        - name: csi-provisioner
          image: registry.k8s.io/sig-storage/csi-provisioner:v5.0.1
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
            - "--feature-gates=Topology=true"
            - "--extra-create-metadata"
            - "--leader-election=true"
            - "--default-fstype=ext4"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        - name: csi-attacher
          image: registry.k8s.io/sig-storage/csi-attacher:v4.7.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
            - "--leader-election=true"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        - name: csi-snapshotter
          image: registry.k8s.io/sig-storage/csi-snapshotter:v8.1.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
            - "--leader-election=true"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        - name: csi-resizer
          image: registry.k8s.io/sig-storage/csi-resizer:v1.12.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=5"
            - "--leader-election=true"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        - name: liveness-probe
          image: registry.k8s.io/sig-storage/livenessprobe:v2.14.0
          args:
            - "--csi-address=/csi/csi.sock"
            - "--health-port=9808"
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
      volumes:
        - name: socket-dir
          emptyDir: {}
---
# Node DaemonSet
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: truenas-csi-node
  namespace: truenas-csi
spec:
  selector:
    matchLabels:
      app: truenas-csi-node
  template:
    metadata:
      labels:
        app: truenas-csi-node
    spec:
      serviceAccountName: truenas-csi-node-sa
${image_pull_secrets}
      hostNetwork: true
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: csi-node
          image: ${truenas_csi_image}
          imagePullPolicy: IfNotPresent
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh", "-c", "mkdir -p /run/lock/iscsi && /usr/sbin/iscsid || true"]
          securityContext:
            privileged: true
          args:
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--node-id=$(NODE_ID)"
            - "--v=4"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: TRUENAS_URL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: truenasURL
            - name: TRUENAS_API_KEY
              valueFrom:
                secretKeyRef:
                  name: truenas-api-credentials
                  key: api-key
            - name: TRUENAS_DEFAULT_POOL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: defaultPool
            - name: TRUENAS_NFS_SERVER
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: nfsServer
            - name: TRUENAS_ISCSI_PORTAL
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: iscsiPortal
            - name: TRUENAS_ISCSI_IQN_BASE
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: iscsiIQNBase
                  optional: true
            - name: TRUENAS_INSECURE_SKIP_VERIFY
              valueFrom:
                configMapKeyRef:
                  name: truenas-csi-config
                  key: truenasInsecure
                  optional: true
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: Bidirectional
            - name: device-dir
              mountPath: /dev
            - name: iscsi-dir
              mountPath: /etc/iscsi
              mountPropagation: Bidirectional
            - name: host-root
              mountPath: /host
              mountPropagation: Bidirectional
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9808
            initialDelaySeconds: 10
            timeoutSeconds: 3
            periodSeconds: 10
            failureThreshold: 5
        - name: csi-node-driver-registrar
          image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.12.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
            - "--v=5"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
            - name: DRIVER_REG_SOCK_PATH
              value: /var/lib/kubelet/plugins/csi.truenas.io/csi.sock
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: registration-dir
              mountPath: /registration
        - name: liveness-probe
          image: registry.k8s.io/sig-storage/livenessprobe:v2.14.0
          args:
            - "--csi-address=/csi/csi.sock"
            - "--health-port=9808"
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
      volumes:
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry/
            type: DirectoryOrCreate
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins/csi.truenas.io/
            type: DirectoryOrCreate
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: Directory
        - name: device-dir
          hostPath:
            path: /dev
        - name: iscsi-dir
          hostPath:
            path: /etc/iscsi
            type: Directory
        - name: host-root
          hostPath:
            path: /
            type: Directory
