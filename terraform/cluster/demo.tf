resource "kubectl_manifest" "mesh_client" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Pod
    metadata:
      name: mesh-client
      namespace: test-mesh
      labels:
        app: mesh-client
    spec:
      containers:
        - name: client
          image: curlimages/curl:latest
          command: ["sleep", "infinity"]
  YAML

  depends_on = [kubectl_manifest.test_mesh_ns, kubectl_manifest.nginx_deployment]
}

resource "kubectl_manifest" "nginx_deployment" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: nginx
      namespace: test-mesh
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: nginx
      template:
        metadata:
          labels:
            app: nginx
        spec:
          containers:
            - name: nginx
              image: public.ecr.aws/nginx/nginx:alpine
              ports:
                - containerPort: 80
              env:
                - name: INSTANCE_ID
                  value: "${var.cluster_name}"
              command:
                - /bin/sh
                - -c
                - |
                  echo "served-by=$INSTANCE_ID" > /usr/share/nginx/html/index.html
                  exec nginx -g 'daemon off;'
  YAML

  depends_on = [kubectl_manifest.test_mesh_ns]
}

resource "kubectl_manifest" "nginx_global_service" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: nginx
      namespace: test-mesh
      annotations:
        service.cilium.io/global: "true"
        service.cilium.io/affinity: "${var.nginx_service_affinity}"
    spec:
      type: ClusterIP
      selector:
        app: nginx
      ports:
        - name: http
          port: 80
          targetPort: 80
  YAML

  depends_on = [kubectl_manifest.test_mesh_ns]
}

resource "kubectl_manifest" "test_mesh_ns" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: test-mesh
      labels:
        clustermesh.cilium.io/global: "true"
  YAML

  depends_on = [helm_release.cilium]
}
