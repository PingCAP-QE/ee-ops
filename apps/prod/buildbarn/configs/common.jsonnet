{
  global: {
    diagnosticsHttpServer: {
      listenAddress: ':8080',
      enablePrometheus: true,
      enablePprof: true,
      enableActiveSpans: true,
    },
    setUmask: { umask: 0 },
  },
  allowAllauthorizerConfiguration: {
    allow: {},
  },
  blobstore: {
    contentAddressableStorage: {
      sharding: {
        hashInitialization: 11946695773637837490,
        shards: [
          {
            backend: { grpc: { address: 'buildbarn-storage-0.buildbarn-storage:8981' } },
            weight: 1,
          },
          {
            backend: { grpc: { address: 'buildbarn-storage-1.buildbarn-storage:8981' } },
            weight: 1,
          },
        ],
      },
    },
    actionCache: {
      completenessChecking: {
        backend: {
          readCaching: {
            fast: {
              sharding: {
                hashInitialization: 11946695773637837490,
                shards: [
                  {
                    backend: { grpc: { address: 'buildbarn-storage-0.buildbarn-storage:8981' } },
                    weight: 1,
                  },
                  {
                    backend: { grpc: { address: 'buildbarn-storage-1.buildbarn-storage:8981' } },
                    weight: 1,
                  },
                ],
              },
            },
            slow: { http: { address: 'http://greenhouse.apps.svc/tidb' } },
            replicator: {
              queued: {
                base: { 'local': {} },
                existenceCache: {
                  cacheSize: 1024 * 1024,
                  cacheDuration: '60s',
                  cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
                },
              },
            },
          },
        },
        maximumTotalTreeSizeBytes: 64 * 1024 * 1024,
      },
    },
  },
  // Remember to set your browserUrl to the ingress of the browser deployment
  browserUrl: 'http://buildbarn-browser:80',
  maximumMessageSizeBytes: 16 * 1024 * 1024,
  httpListenAddress: ':80',
}
