import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigor } from '@ohos/hvigor';
import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

// libshared.so / libshared_api.h 是 shared (Kotlin/Native ohosArm64) 的构建产物，
// 不入库。关联编译内联在此，不依赖外部 hvigor 插件包：DevEco 内置
// pnpm 7.30 + Node 18.20 拉 npm 元数据会报 ERR_INVALID_THIS。
const ENTRY_DIR = __dirname;                            // ohosApp/entry
const PROJECT_DIR = path.resolve(ENTRY_DIR, '../..');  // 仓库根
const SO_DST = path.join(ENTRY_DIR, 'libs/arm64-v8a/libshared.so');
const HEADER_DST = path.join(ENTRY_DIR, 'src/main/cpp/thirdparty/biz_entry/libshared_api.h');

const gradleEnv = {
  ...process.env,
  KUIKLY_AGP_VERSION: '7.4.2',
  KUIKLY_KOTLIN_VERSION: '2.0.21-KBA-010',
};
// 去掉宿主注入的 node shim，避免子进程继承后影响 Gradle。
delete gradleEnv.NODE_OPTIONS;

function sharedSoPlugin() {
  return {
    pluginId: 'KuiklySharedSoPlugin',
    apply(node: any) {
      node.registerTask({
        name: 'kuikly_build_shared',
        run() {
          const buildMode = hvigor.getParameter().getExtParams().buildMode || 'debug';
          const capitalMode = buildMode.charAt(0).toUpperCase() + buildMode.slice(1);
          // shared/build.ohos.gradle.kts 的 binaries.sharedLib 不带名字：
          // debug -> linkDebugSharedOhosArm64 / debugShared/
          // release -> linkReleaseSharedOhosArm64 / releaseShared/
          const linkTask = `link${capitalMode}SharedOhosArm64`;
          const productDir = path.join(
            PROJECT_DIR, 'shared/build/bin/ohosArm64', `${buildMode}Shared`);

          for (const file of [SO_DST, HEADER_DST]) {
            if (fs.existsSync(file)) {
              fs.rmSync(file);
            }
          }

          console.log(`==> 关联编译 shared (ohosArm64): :shared:${linkTask}`);
          execFileSync(
            './gradlew',
            ['-c', 'settings.ohos.gradle.kts', `:shared:${linkTask}`, '--console=plain'],
            { cwd: PROJECT_DIR, env: gradleEnv, stdio: 'inherit' },
          );

          const soSrc = path.join(productDir, 'libshared.so');
          const headerSrc = path.join(productDir, 'libshared_api.h');
          if (!fs.existsSync(soSrc) || !fs.existsSync(headerSrc)) {
            throw new Error(`[KuiklySharedSoPlugin] 未找到 Gradle 产物：${productDir}`);
          }
          fs.mkdirSync(path.dirname(SO_DST), { recursive: true });
          fs.mkdirSync(path.dirname(HEADER_DST), { recursive: true });
          fs.copyFileSync(soSrc, SO_DST);
          fs.copyFileSync(headerSrc, HEADER_DST);
          console.log('==> 关联编译 shared 完成');
        },
        // default 取自 build-profile.json5 的 targets[].name；
        // 声明为 postDependency，使本 task 排在 PreBuild 之前。
        postDependencies: ['default@PreBuild'],
      });
    },
  };
}

export default {
  system: hapTasks,
  plugins: [sharedSoPlugin()],
};
