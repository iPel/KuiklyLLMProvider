import { KuiklyNativeManager } from '@kuikly-open/render';
import Napi from 'libkuikly_entry.so';

class MyNativeManager extends KuiklyNativeManager {
  loadNative(): number {
    return Napi.initKuikly();
  }
}

const globalNativeManager = new MyNativeManager();

export default globalNativeManager;
