interface Env {
  RELAY: DurableObjectNamespace;
  RELAY_TOKEN: string;
}

declare global {
  interface SubtleCrypto {
    timingSafeEqual(a: ArrayBuffer | ArrayBufferView, b: ArrayBuffer | ArrayBufferView): boolean;
  }
}
