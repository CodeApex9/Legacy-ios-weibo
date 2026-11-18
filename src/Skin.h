#ifndef LEGACY_SKIN_H
#define LEGACY_SKIN_H

/* 运行时皮肤：0=V0.3 深蓝皮革（默认，原有样式），1=iOS6 提醒事项（深灰拉丝）。
   持久化到 ~/weibo_skin.txt，重启恢复。所有界面位图经 SkinImage() 取名，
   这样一套代码同时驱动两套皮肤，不需要编译开关。 */

int         SkinCurrent(void);              /* 当前皮肤 id */
void        SkinSet(int skin);              /* 切换并持久化（0/1） */
void        SkinToggle(void);               /* 0<->1 切换 */
const char *SkinName(void);                 /* 界面提示用：「皮革」/「提醒事项」 */

/* 传入 V0.3 的资源名（如 "NavBar"），返回当前皮肤对应的资源名。
   提醒事项皮肤下所有位图都带 R_ 前缀；没有对应资源时原样返回。 */
NSString   *SkinImage(NSString *name);

#endif
