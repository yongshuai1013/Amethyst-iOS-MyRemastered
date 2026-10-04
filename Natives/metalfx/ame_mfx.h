// Natives/metalfx/ame_mfx.h
// 阶段 0：MetalFX（Apple 官方超分 / 插帧）能力探针。
//
// MetalFX 能否用于本启动器，取决于三件事，缺一不可：
//
//   1) 链上存在 MTLDevice
//      MobileGL-gles / ANGLE 的 GLES 后端在 iOS 上本就跑在 Metal 之上，
//      因此这一条成立；而 zink / MoltenVK 那条链上没有一个 MTLTexture，
//      MetalFX 只吃 MTLTexture，故那条链整条不成立。
//
//   2) ANGLE 暴露 EGL_ANGLE_metal_texture_client_buffer（EGL_METAL_TEXTURE_ANGLE
//      = 0x34A7）
//      只有它才能把「我们自己创建的 MTLTexture」导入成一个 GL 纹理
//      （glEGLImageTargetTexture2DOES），于是 MC 可以渲染进去、我们手里又同时
//      握着同一个 MTLTexture —— 零拷贝，这是整个方案的枢纽。
//
//   3) 设备与系统支持对应的 MetalFX 组件
//      SpatialScaler iOS 16+ / TemporalScaler iOS 16+ /
//      FrameInterpolator iOS 26+（随 Metal 4 引入）。
//
// 本探针只往日志打印，不改变任何渲染行为、不创建任何 GL / Metal 资源。
// 不做探测时行为与不存在完全一致。
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// 打印一次能力探测结果。可重复调用，内部只真正执行一次。
///
/// 建议在有 EGL 上下文之后调用（pojavSwapBuffers 首次进入处），否则第 2 项
/// 会因为拿不到 EGLDisplay 而无从判断 —— 那本身也是一条有用的结论。
void ameMfxProbe(void);

#ifdef __cplusplus
}
#endif
