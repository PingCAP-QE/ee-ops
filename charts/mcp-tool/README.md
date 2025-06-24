# mcp-tool Helm Chart

This is a generic Helm chart for deploying an MCP tool that serves over the SSE (Server-Sent Events) protocol.

## Features
- **SSE Protocol**: Designed for applications serving over SSE (Server-Sent Events).
- **Custom Image**: Set your own container image via `values.yaml`.
- **Environment Variables**: Configure environment variables directly or from ConfigMaps/Secrets.
- **Custom Command/Args**: Override the container's startup command and arguments.

## Usage

### Set the Container Image
```yaml
image:
  repository: <your-image-repository>
  tag: <your-tag>
```

### Environment Variables
```yaml
env:
  - name: FOO
    value: "bar"

# Or from ConfigMaps/Secrets
envFrom:
  - configMapRef:
      name: my-configmap
  - secretRef:
      name: my-secret
```

### Custom Command and Args
```yaml
command:
  - /bin/mycmd
args:
  - --serve-sse
  - --port=8080
```

## Example
```shell
helm install my-mcp-tool ./charts/mcp-tool \
  --set image.repository=myrepo/mcp-tool \
  --set image.tag=latest \
  --set service.port=8080
```

## SSE Protocol
Ensure your application serves HTTP responses with the `Content-Type: text/event-stream` header for SSE. 
