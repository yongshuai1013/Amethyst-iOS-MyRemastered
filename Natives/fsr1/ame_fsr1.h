// Natives/fsr1/ame_fsr1.h
// 启动器侧 FSR1（EASU 上采样 + RCAS 锐化）。
//
// 与渲染器侧实现（MobileGlues 的 gl/FSR1）的根本区别：本模块位于 EGL 之上、
// 渲染器之外，只依赖「当前 EGL 上下文里能解析到的 GL 入口点」，因此不挑后端
// —— MG / MobileGlues / ANGLE / LTW / SFPEW 任一组合走的是同一条路。
//
// 工作方式（缩放由 video.resolution 提供）：
//   * EGL window surface 保持全分辨率（这是 framebuffer 0，也是最终 present 的面）
//   * 交给 MC 的窗口尺寸是缩放后的低分辨率，MC 因此把 viewport 设成低分辨率，
//     画面落在 framebuffer 0 左下角的一块矩形里
//   * 本模块在 eglSwapBuffers 之前把那块矩形取出来，EASU 上采样到全分辨率，
//     RCAS 锐化，写回 framebuffer 0，再 swap
//
// 关闭时本模块不参与任何 GL 调用，行为与不存在完全一致。
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// FSR1 当前是否真正生效。
///
/// 只有「开关打开 + scale < 100% + 资源建好 + 期间没有出过致命错误」才为真。
/// egl_bridge 用它决定 viewport 守护应该对齐到哪个尺寸：为真时对齐渲染分辨率
/// （低），否则对齐 surface（全）。二者始终同源，切换的瞬间也不会出现
/// 「MC 画低分辨率而守护把它纠正成全分辨率」的半状态。
bool ameFsr1Active(void);

/// 是否需要「surface 全分辨率 + 交给 MC 的窗口尺寸为缩放后尺寸」这一几何布局。
///
/// 宿主（SurfaceViewController 决定 drawableSize 的地方）用它区分两种语义：
///   * 为假：surface 就是渲染分辨率，缩放直接体现在 surface 上
///     （CoreAnimation 负责拉伸到屏幕，双线性）
///   * 为真：surface 必须是全分辨率，交给 MC 的 windowWidth/Height 仍是缩放后的
///     值，中间那一步由本模块的 EASU 完成（比双线性质量高）
bool ameFsr1NeedsFullResSurface(void);

/// 取渲染分辨率。返回 false 表示调用方应直接用 surface 尺寸。
/// FSR1 未生效时 *outW/*outH 会写成 surface 尺寸，方便调用方无分支使用。
bool ameFsr1RenderSize(int surfaceW, int surfaceH, int *outW, int *outH);

/// 在 eglSwapBuffers 之前调用。surfaceW/surfaceH 是 EGL surface 的像素尺寸。
///
/// 内部任何一步失败都会永久关闭 FSR1（ameFsr1Active 随之变假），此后本函数
/// 立即返回 —— 绝不会让画面停在中途状态。
void ameFsr1Present(int surfaceW, int surfaceH);

/// 只保证「画面铺满」，不做上采样。
///
/// egl_bridge 在跳过了 FSR1 pass 的帧（编译风暴期、符号未解析等）调用它：
/// 只要本帧不上采样，就必须把左下角内容铺满，否则画面缩在 surface 一角且
/// 无法自愈（surface 只创建一次）。
void ameFsr1KeepFullScreen(int surfaceW, int surfaceH);

/// 供调试：把当前状态打进日志。
void ameFsr1DumpState(void);

#ifdef __cplusplus
}
#endif
