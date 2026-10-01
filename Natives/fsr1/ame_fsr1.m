// Natives/fsr1/ame_fsr1.m
// 启动器侧 FSR1（EASU + RCAS）实现。
//
// 设计约束（每一条都对应一次实测到的失败，改动时请连同注释一起读）：
//
// 1. 不 include 任何 GL 头文件。iOS 自带 OpenGLES.framework 的桩与本进程建
//    立的 EGL 上下文毫无关系；一旦链接到它的符号，写 viewport 会静默无效。
//    故所有 GL 入口点都经函数指针 + 硬编码枚举，枚举值取自 GLES 3.0 规范。
//
// 2. GL 入口点只认「可信实现」：渲染器 dylib 句柄 → eglGetProcAddress →
//    dlsym(RTLD_DEFAULT)，每一条都要过 dladdr 验明镜像，拒绝系统框架。
//    与 egl_bridge.m 的 pojavResolveTrustedGl 同一套策略。
//
// 3. 默认关闭。打开的唯一途径是 video.fsr1 设置项（或 AMETHYST_FSR1=1）。
//    关闭路径上本文件不调用任何 GL 函数。
//
// 4. 任何一步失败都永久自我关闭。宁可退回无 FSR1 的完整画面，也绝不停在
//    「游戏画低分辨率、没人上采样」的黑屏/局部画面状态。
//
// EASU / RCAS 的算法取自 AMD FidelityFX FSR1（ffx_fsr1.h，MIT 许可）的
// 32-bit non-packed 变体，gather4 被展开为直接 texture() 采样 —— GLES 3.0
// 没有 textureGather，展开后是 12 次采样，语义与原版一致。

#import "ame_fsr1.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#import "LauncherPreferences.h"

// ---------------------------------------------------------------------------
// GLES 3.0 枚举（不引头文件，避免链接到系统桩）
// ---------------------------------------------------------------------------
#define AME_GL_TEXTURE_2D              0x0DE1
#define AME_GL_RGBA8                   0x8058
#define AME_GL_RGBA                    0x1908
#define AME_GL_UNSIGNED_BYTE           0x1401
#define AME_GL_FLOAT                   0x1406
#define AME_GL_LINEAR                  0x2601
#define AME_GL_NEAREST                 0x2600
#define AME_GL_CLAMP_TO_EDGE           0x812F
#define AME_GL_TEXTURE_MIN_FILTER      0x2801
#define AME_GL_TEXTURE_MAG_FILTER      0x2800
#define AME_GL_TEXTURE_WRAP_S          0x2802
#define AME_GL_TEXTURE_WRAP_T          0x2803
#define AME_GL_TEXTURE_MAX_LEVEL       0x813D
#define AME_GL_TEXTURE0                0x84C0
#define AME_GL_ACTIVE_TEXTURE          0x84E0
#define AME_GL_TEXTURE_BINDING_2D      0x8069
#define AME_GL_FRAMEBUFFER             0x8D40
#define AME_GL_READ_FRAMEBUFFER        0x8CA8
#define AME_GL_DRAW_FRAMEBUFFER        0x8CA9
#define AME_GL_FRAMEBUFFER_BINDING     0x8CA6
#define AME_GL_COLOR_ATTACHMENT0       0x8CE0
#define AME_GL_FRAMEBUFFER_COMPLETE    0x8CD5
#define AME_GL_COLOR_BUFFER_BIT        0x00004000
#define AME_GL_ARRAY_BUFFER            0x8892
#define AME_GL_ARRAY_BUFFER_BINDING    0x8894
#define AME_GL_STATIC_DRAW             0x88E4
#define AME_GL_VERTEX_SHADER           0x8B31
#define AME_GL_FRAGMENT_SHADER         0x8B30
#define AME_GL_COMPILE_STATUS          0x8B81
#define AME_GL_LINK_STATUS             0x8B82
#define AME_GL_CURRENT_PROGRAM         0x8B8D
#define AME_GL_VERTEX_ARRAY_BINDING    0x85B5
#define AME_GL_TRIANGLES               0x0004
#define AME_GL_BLEND                   0x0BE2
#define AME_GL_DEPTH_TEST              0x0B71
#define AME_GL_STENCIL_TEST            0x0B90
#define AME_GL_CULL_FACE               0x0B44
#define AME_GL_SCISSOR_TEST            0x0C11
#define AME_GL_VIEWPORT                0x0BA2
#define AME_GL_SAMPLES                 0x80A9
#define AME_GL_UNPACK_ALIGNMENT        0x0CF5
#define AME_GL_NO_ERROR                0x0000

typedef void (*ame_fn_v)(void);

// ---------------------------------------------------------------------------
// GL 入口点解析
// ---------------------------------------------------------------------------
static void *g_rendererHandle = NULL;
static int   g_rendererMiss   = 0;
// 诊断用：解析失败/空转都只打一次，避免每帧刷屏（日志会瞬间顶满）。
static BOOL  g_resolveFailLogged = NO;
static BOOL  g_unresolvedLogged  = NO;
static BOOL  g_idleLogged        = NO;

static void *ameRendererHandle(void) {
    if (g_rendererHandle != NULL) return g_rendererHandle;
    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return NULL;
    g_rendererMiss++;
    if (g_rendererMiss > 1 && (g_rendererMiss % 16) != 0) return NULL;
    NSString *path = [NSString stringWithFormat:@"@rpath/%s", renderer];
    g_rendererHandle = dlopen(path.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    return g_rendererHandle;
}

static bool ameSymbolTrusted(const void *sym) {
    if (sym == NULL) return false;
    Dl_info info;
    if (dladdr(sym, &info) == 0 || info.dli_fname == NULL) return false;
    const char *img = info.dli_fname;
    return (strstr(img, "OpenGLES.framework") == NULL &&
            strstr(img, "OpenGL.framework") == NULL);
}

static void *ameResolveGL(const char *name) {
    void *rh = ameRendererHandle();
    if (rh != NULL) {
        void *p = dlsym(rh, name);
        if (ameSymbolTrusted(p)) return p;
    }
    void *eglGPA = dlsym(RTLD_DEFAULT, "eglGetProcAddress");
    if (eglGPA != NULL) {
        typedef void *(*fn_gpa_t)(const char *);
        void *p = ((fn_gpa_t)eglGPA)(name);
        if (ameSymbolTrusted(p)) return p;
    }
    void *p = dlsym(RTLD_DEFAULT, name);
    return ameSymbolTrusted(p) ? p : NULL;
}

// 需要的 GL 入口点
typedef unsigned int ame_GLuint;
typedef int          ame_GLint;
typedef int          ame_GLsizei;
typedef unsigned int ame_GLenum;
typedef unsigned char ame_GLboolean;
typedef float        ame_GLfloat;

static void *(*ame_glGetIntegerv)(ame_GLenum, ame_GLint *);
static void (*ame_glViewport)(ame_GLint, ame_GLint, ame_GLsizei, ame_GLsizei);
static void (*ame_glGenTextures)(ame_GLsizei, ame_GLuint *);
static void (*ame_glDeleteTextures)(ame_GLsizei, const ame_GLuint *);
static void (*ame_glBindTexture)(ame_GLenum, ame_GLuint);
static void (*ame_glTexImage2D)(ame_GLenum, ame_GLint, ame_GLint, ame_GLsizei, ame_GLsizei,
                                ame_GLint, ame_GLenum, ame_GLenum, const void *);
static void (*ame_glTexParameteri)(ame_GLenum, ame_GLenum, ame_GLint);
static void (*ame_glGenFramebuffers)(ame_GLsizei, ame_GLuint *);
static void (*ame_glDeleteFramebuffers)(ame_GLsizei, const ame_GLuint *);
static void (*ame_glBindFramebuffer)(ame_GLenum, ame_GLuint);
static void (*ame_glFramebufferTexture2D)(ame_GLenum, ame_GLenum, ame_GLenum, ame_GLuint, ame_GLint);
static ame_GLenum (*ame_glCheckFramebufferStatus)(ame_GLenum);
static void (*ame_glBlitFramebuffer)(ame_GLint, ame_GLint, ame_GLint, ame_GLint,
                                     ame_GLint, ame_GLint, ame_GLint, ame_GLint,
                                     ame_GLenum, ame_GLenum);
static void (*ame_glGenBuffers)(ame_GLsizei, ame_GLuint *);
static void (*ame_glDeleteBuffers)(ame_GLsizei, const ame_GLuint *);
static void (*ame_glBindBuffer)(ame_GLenum, ame_GLuint);
static void (*ame_glBufferData)(ame_GLenum, long, const void *, ame_GLenum);
static void (*ame_glGenVertexArrays)(ame_GLsizei, ame_GLuint *);
static void (*ame_glDeleteVertexArrays)(ame_GLsizei, const ame_GLuint *);
static void (*ame_glBindVertexArray)(ame_GLuint);
static void (*ame_glVertexAttribPointer)(ame_GLuint, ame_GLint, ame_GLenum, ame_GLboolean,
                                         ame_GLsizei, const void *);
static void (*ame_glEnableVertexAttribArray)(ame_GLuint);
static ame_GLuint (*ame_glCreateShader)(ame_GLenum);
static void (*ame_glShaderSource)(ame_GLuint, ame_GLsizei, const char *const *, const ame_GLint *);
static void (*ame_glCompileShader)(ame_GLuint);
static void (*ame_glGetShaderiv)(ame_GLuint, ame_GLenum, ame_GLint *);
static void (*ame_glGetShaderInfoLog)(ame_GLuint, ame_GLsizei, ame_GLsizei *, char *);
static void (*ame_glDeleteShader)(ame_GLuint);
static ame_GLuint (*ame_glCreateProgram)(void);
static void (*ame_glAttachShader)(ame_GLuint, ame_GLuint);
static void (*ame_glLinkProgram)(ame_GLuint);
static void (*ame_glGetProgramiv)(ame_GLuint, ame_GLenum, ame_GLint *);
static void (*ame_glGetProgramInfoLog)(ame_GLuint, ame_GLsizei, ame_GLsizei *, char *);
static void (*ame_glDeleteProgram)(ame_GLuint);
static void (*ame_glUseProgram)(ame_GLuint);
static ame_GLint (*ame_glGetUniformLocation)(ame_GLuint, const char *);
static void (*ame_glUniform1i)(ame_GLint, ame_GLint);
static void (*ame_glUniform1f)(ame_GLint, ame_GLfloat);
static void (*ame_glUniform2f)(ame_GLint, ame_GLfloat, ame_GLfloat);
static void (*ame_glUniform4f)(ame_GLint, ame_GLfloat, ame_GLfloat, ame_GLfloat, ame_GLfloat);
static void (*ame_glActiveTexture)(ame_GLenum);
static void (*ame_glDrawArrays)(ame_GLenum, ame_GLint, ame_GLsizei);
static void (*ame_glEnable)(ame_GLenum);
static void (*ame_glDisable)(ame_GLenum);
static ame_GLenum (*ame_glGetError)(void);
static void (*ame_glClearColor)(ame_GLfloat, ame_GLfloat, ame_GLfloat, ame_GLfloat);
static void (*ame_glClear)(ame_GLenum);
static void (*ame_glPixelStorei)(ame_GLenum, ame_GLint);

#define AME_RESOLVE(dst, name) do { (dst) = ameResolveGL(name); if ((dst) == NULL) { \
    if (!g_resolveFailLogged) { g_resolveFailLogged = YES; \
        NSLog(@"[FSR1] resolve failed: %s", name); } \
    allOK = NO; } } while (0)

static BOOL ameResolveAll(void) {
    BOOL allOK = YES;
    AME_RESOLVE(ame_glGetIntegerv, "glGetIntegerv");
    AME_RESOLVE(ame_glViewport, "glViewport");
    AME_RESOLVE(ame_glGenTextures, "glGenTextures");
    AME_RESOLVE(ame_glDeleteTextures, "glDeleteTextures");
    AME_RESOLVE(ame_glBindTexture, "glBindTexture");
    AME_RESOLVE(ame_glTexImage2D, "glTexImage2D");
    AME_RESOLVE(ame_glTexParameteri, "glTexParameteri");
    AME_RESOLVE(ame_glGenFramebuffers, "glGenFramebuffers");
    AME_RESOLVE(ame_glDeleteFramebuffers, "glDeleteFramebuffers");
    AME_RESOLVE(ame_glBindFramebuffer, "glBindFramebuffer");
    AME_RESOLVE(ame_glFramebufferTexture2D, "glFramebufferTexture2D");
    AME_RESOLVE(ame_glCheckFramebufferStatus, "glCheckFramebufferStatus");
    AME_RESOLVE(ame_glBlitFramebuffer, "glBlitFramebuffer");
    AME_RESOLVE(ame_glGenBuffers, "glGenBuffers");
    AME_RESOLVE(ame_glDeleteBuffers, "glDeleteBuffers");
    AME_RESOLVE(ame_glBindBuffer, "glBindBuffer");
    AME_RESOLVE(ame_glBufferData, "glBufferData");
    AME_RESOLVE(ame_glGenVertexArrays, "glGenVertexArrays");
    AME_RESOLVE(ame_glDeleteVertexArrays, "glDeleteVertexArrays");
    AME_RESOLVE(ame_glBindVertexArray, "glBindVertexArray");
    AME_RESOLVE(ame_glVertexAttribPointer, "glVertexAttribPointer");
    AME_RESOLVE(ame_glEnableVertexAttribArray, "glEnableVertexAttribArray");
    AME_RESOLVE(ame_glCreateShader, "glCreateShader");
    AME_RESOLVE(ame_glShaderSource, "glShaderSource");
    AME_RESOLVE(ame_glCompileShader, "glCompileShader");
    AME_RESOLVE(ame_glGetShaderiv, "glGetShaderiv");
    AME_RESOLVE(ame_glGetShaderInfoLog, "glGetShaderInfoLog");
    AME_RESOLVE(ame_glDeleteShader, "glDeleteShader");
    AME_RESOLVE(ame_glCreateProgram, "glCreateProgram");
    AME_RESOLVE(ame_glAttachShader, "glAttachShader");
    AME_RESOLVE(ame_glLinkProgram, "glLinkProgram");
    AME_RESOLVE(ame_glGetProgramiv, "glGetProgramiv");
    AME_RESOLVE(ame_glGetProgramInfoLog, "glGetProgramInfoLog");
    AME_RESOLVE(ame_glDeleteProgram, "glDeleteProgram");
    AME_RESOLVE(ame_glUseProgram, "glUseProgram");
    AME_RESOLVE(ame_glGetUniformLocation, "glGetUniformLocation");
    AME_RESOLVE(ame_glUniform1i, "glUniform1i");
    AME_RESOLVE(ame_glUniform1f, "glUniform1f");
    AME_RESOLVE(ame_glUniform2f, "glUniform2f");
    AME_RESOLVE(ame_glUniform4f, "glUniform4f");
    AME_RESOLVE(ame_glActiveTexture, "glActiveTexture");
    AME_RESOLVE(ame_glDrawArrays, "glDrawArrays");
    AME_RESOLVE(ame_glEnable, "glEnable");
    AME_RESOLVE(ame_glDisable, "glDisable");
    AME_RESOLVE(ame_glGetError, "glGetError");
    AME_RESOLVE(ame_glClearColor, "glClearColor");
    AME_RESOLVE(ame_glClear, "glClear");
    AME_RESOLVE(ame_glPixelStorei, "glPixelStorei");
    return allOK;
}

// ---------------------------------------------------------------------------
// 着色器
//
// 顶点着色器共用于两个 pass：无变换全屏三角形。
// 片元着色器：EASU（低分辨率 -> 全分辨率）与 RCAS（锐化）。
// ---------------------------------------------------------------------------
static const char *kFSRVert =
"#version 300 es\n"
"layout(location = 0) in vec2 aPos;\n"
"out vec2 vUV;\n"
"void main(){\n"
"  vUV = aPos * 0.5 + 0.5;\n"
"  gl_Position = vec4(aPos, 0.0, 1.0);\n"
"}\n";

// —— EASU ——
// 算法来自 AMD FidelityFX FSR1（ffx_fsr1.h）的 32-bit non-packed 变体。
// 原版用 textureGather 一次取 4 个 tap 的同一通道；GLES 3.0 没有
// textureGather，这里把它展开成 12 次 texture()，语义一致。
// 三处 rcp/rsqrt 在原版是低精度近似（APrxLoRcpF1 / APrxLoRsqF1），此处用
// 精确版本并加了 epsilon 保护：退化情形（整块平坦色，梯度为 0）下
// 0 * inf 会出 NaN，原版依赖低精度近似的非 IEEE 行为躲开，这里显式躲开。
static const char *kFSRFragEASU =
"#version 300 es\n"
"precision highp float;\n"
"uniform sampler2D uSrc;\n"
"uniform vec2  uInputSize;   // render resolution (low)\n"
"uniform vec2  uOutputSize;  // surface resolution (full)\n"
"uniform vec4  uCon0;\n"
"in  vec2 vUV;\n"
"out vec4 fragColor;\n"
"\n"
"vec2 texel() { return 1.0 / uInputSize; }\n"
"vec3 fetchRGB(vec2 ip){ return texture(uSrc, (ip + vec2(0.5)) * texel()).rgb; }\n"
"float luma2(vec3 c){ return c.b * 0.5 + (c.r * 0.5 + c.g); }\n"
"\n"
"// Per-tap weight and accumulation\n"
"void tapF(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len,\n"
"          float lob, float clp, vec3 c){\n"
"  vec2 v;\n"
"  v.x = (off.x * ( dir.x)) + (off.y * dir.y);\n"
"  v.y = (off.x * (-dir.y)) + (off.y * dir.x);\n"
"  v *= len;\n"
"  float d2 = v.x * v.x + v.y * v.y;\n"
"  d2 = min(d2, clp);\n"
"  // lancos2 approximation without sin/rcp/sqrt:\n"
"  //   (25/16*(2/5*x^2-1)^2-(25/16-1)) * (1/4*x^2-1)^2\n"
"  float wB = (2.0/5.0) * d2 + (-1.0);\n"
"  float wA = lob * d2 + (-1.0);\n"
"  wB *= wB;\n"
"  wA *= wA;\n"
"  wB = (25.0/16.0) * wB + (-(25.0/16.0 - 1.0));\n"
"  float w = wB * wA;\n"
"  aC += c * w;\n"
"  aW += w;\n"
"}\n"
"\n"
"// Accumulate direction and length (one bilinear corner)\n"
"void setF(inout vec2 dir, inout float len, vec2 pp, float w,\n"
"          float lA, float lB, float lC, float lD, float lE){\n"
"  float dc = lD - lC;\n"
"  float cb = lC - lB;\n"
"  float lenX = max(abs(dc), abs(cb));\n"
"  lenX = 1.0 / max(lenX, 1e-8);\n"
"  float dirX = lD - lB;\n"
"  dir.x += dirX * w;\n"
"  lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);\n"
"  lenX *= lenX;\n"
"  len += lenX * w;\n"
"  float ec = lE - lC;\n"
"  float ca = lC - lA;\n"
"  float lenY = max(abs(ec), abs(ca));\n"
"  lenY = 1.0 / max(lenY, 1e-8);\n"
"  float dirY = lE - lA;\n"
"  dir.y += dirY * w;\n"
"  lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);\n"
"  lenY *= lenY;\n"
"  len += lenY * w;\n"
"}\n"
"\n"
"void main(){\n"
"  // Integer output pixel position (GLES/GL origin is bottom-left)\n"
"  vec2 ip = floor(gl_FragCoord.xy);\n"
"  vec2 pp = ip * uCon0.xy + uCon0.zw;\n"
"  vec2 fp = floor(pp);\n"
"  pp -= fp;\n"
"\n"
"  // 12-tap layout (relative to f):\n"
"  //      b   c\n"
"  //   e  f   g   h\n"
"  //   i  j   k   l\n"
"  //      n   o\n"
"  vec3 bC = fetchRGB(fp + vec2( 0.0, -1.0));\n"
"  vec3 cC = fetchRGB(fp + vec2( 1.0, -1.0));\n"
"  vec3 eC = fetchRGB(fp + vec2(-1.0,  0.0));\n"
"  vec3 fC = fetchRGB(fp + vec2( 0.0,  0.0));\n"
"  vec3 gC = fetchRGB(fp + vec2( 1.0,  0.0));\n"
"  vec3 hC = fetchRGB(fp + vec2( 2.0,  0.0));\n"
"  vec3 iC = fetchRGB(fp + vec2(-1.0,  1.0));\n"
"  vec3 jC = fetchRGB(fp + vec2( 0.0,  1.0));\n"
"  vec3 kC = fetchRGB(fp + vec2( 1.0,  1.0));\n"
"  vec3 lC = fetchRGB(fp + vec2( 2.0,  1.0));\n"
"  vec3 nC = fetchRGB(fp + vec2( 0.0,  2.0));\n"
"  vec3 oC = fetchRGB(fp + vec2( 1.0,  2.0));\n"
"\n"
"  float bL = luma2(bC), cL = luma2(cC), eL = luma2(eC), fL = luma2(fC);\n"
"  float gL = luma2(gC), hL = luma2(hC), iL = luma2(iC), jL = luma2(jC);\n"
"  float kL = luma2(kC), lL = luma2(lC), nL = luma2(nC), oL = luma2(oC);\n"
"\n"
"  vec2  dir = vec2(0.0);\n"
"  float len = 0.0;\n"
"  setF(dir, len, pp, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);\n"
"  setF(dir, len, pp,        pp.x  * (1.0 - pp.y), cL, fL, gL, hL, kL);\n"
"  setF(dir, len, pp, (1.0 - pp.x) *        pp.y , fL, iL, jL, kL, nL);\n"
"  setF(dir, len, pp,        pp.x  *        pp.y , gL, jL, kL, lL, oL);\n"
"\n"
"  vec2  dir2 = dir * dir;\n"
"  float dirR = dir2.x + dir2.y;\n"
"  bool  zro  = dirR < (1.0 / 32768.0);\n"
"  dirR = inversesqrt(max(dirR, 1e-12));\n"
"  dirR = zro ? 1.0 : dirR;\n"
"  dir.x = zro ? 1.0 : dir.x;\n"
"  dir *= vec2(dirR);\n"
"\n"
"  len = len * 0.5;\n"
"  len *= len;\n"
"\n"
"  float stretch = (dir.x * dir.x + dir.y * dir.y) *\n"
"                  (1.0 / max(max(abs(dir.x), abs(dir.y)), 1e-8));\n"
"  vec2  len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 + (-0.5) * len);\n"
"  float lob = 0.5 + ((1.0/4.0 - 0.04) - 0.5) * len;\n"
"  float clp = 1.0 / max(lob, 1e-8);\n"
"\n"
"  vec3 min4 = min(min(min(fC, gC), jC), kC);\n"
"  vec3 max4 = max(max(max(fC, gC), jC), kC);\n"
"\n"
"  vec3  aC = vec3(0.0);\n"
"  float aW = 0.0;\n"
"  vec2  ppv = pp;\n"
"  tapF(aC, aW, vec2( 0.0, -1.0) - ppv, dir, len2, lob, clp, bC);\n"
"  tapF(aC, aW, vec2( 1.0, -1.0) - ppv, dir, len2, lob, clp, cC);\n"
"  tapF(aC, aW, vec2(-1.0,  1.0) - ppv, dir, len2, lob, clp, iC);\n"
"  tapF(aC, aW, vec2( 0.0,  1.0) - ppv, dir, len2, lob, clp, jC);\n"
"  tapF(aC, aW, vec2( 0.0,  0.0) - ppv, dir, len2, lob, clp, fC);\n"
"  tapF(aC, aW, vec2(-1.0,  0.0) - ppv, dir, len2, lob, clp, eC);\n"
"  tapF(aC, aW, vec2( 1.0,  1.0) - ppv, dir, len2, lob, clp, kC);\n"
"  tapF(aC, aW, vec2( 2.0,  1.0) - ppv, dir, len2, lob, clp, lC);\n"
"  tapF(aC, aW, vec2( 2.0,  0.0) - ppv, dir, len2, lob, clp, hC);\n"
"  tapF(aC, aW, vec2( 1.0,  0.0) - ppv, dir, len2, lob, clp, gC);\n"
"  tapF(aC, aW, vec2( 1.0,  2.0) - ppv, dir, len2, lob, clp, oC);\n"
"  tapF(aC, aW, vec2( 0.0,  2.0) - ppv, dir, len2, lob, clp, nC);\n"
"\n"
"  vec3 pix = aC * (1.0 / max(aW, 1e-8));\n"
"  pix = clamp(pix, min4, max4);   // clamp away overshoot (deringing)\n"
"  fragColor = vec4(pix, 1.0);\n"
"}\n";

// —— RCAS ——
// 同样取自 ffx_fsr1.h 的 32-bit non-packed 变体，FSR_RCAS_DENOISE 关闭。
// uSharp = FsrRcasCon(sharpnessStops) 的 con.x。
static const char *kFSRFragRCAS =
"#version 300 es\n"
"precision highp float;\n"
"uniform sampler2D uSrc;\n"
"uniform vec2  uOutputSize;\n"
"uniform float uSharp;\n"
"in  vec2 vUV;\n"
"out vec4 fragColor;\n"
"\n"
"vec3 load(ivec2 p){ return texelFetch(uSrc, p, 0).rgb; }\n"
"float luma2(vec3 c){ return c.b * 0.5 + (c.r * 0.5 + c.g); }\n"
"\n"
"void main(){\n"
"  ivec2 sp = ivec2(gl_FragCoord.xy);\n"
"  ivec2 maxp = ivec2(uOutputSize) - ivec2(1);\n"
"  ivec2 bp = clamp(sp + ivec2( 0, -1), ivec2(0), maxp);\n"
"  ivec2 dp = clamp(sp + ivec2(-1,  0), ivec2(0), maxp);\n"
"  ivec2 ep = clamp(sp,                ivec2(0), maxp);\n"
"  ivec2 fp = clamp(sp + ivec2( 1,  0), ivec2(0), maxp);\n"
"  ivec2 hp = clamp(sp + ivec2( 0,  1), ivec2(0), maxp);\n"
"  vec3 b = load(bp), d = load(dp), e = load(ep), f = load(fp), h = load(hp);\n"
"\n"
"  float bL = luma2(b), dL = luma2(d), eL = luma2(e), fL = luma2(f), hL = luma2(h);\n"
"\n"
"  // Noise detection: sharpen less on noisy pixels\n"
"  float nz = 0.25 * bL + 0.25 * dL + 0.25 * fL + 0.25 * hL - eL;\n"
"  float mx5 = max(max(max(max(bL, dL), eL), fL), hL);\n"
"  float mn5 = min(min(min(min(bL, dL), eL), fL), hL);\n"
"  nz = clamp(abs(nz) * (1.0 / max(mx5 - mn5, 1e-8)), 0.0, 1.0);\n"
"  nz = (-0.5) * nz + 1.0;\n"
"\n"
"  vec3 mn4 = min(min(min(b, d), f), h);\n"
"  vec3 mx4 = max(max(max(b, d), f), h);\n"
"\n"
"  vec2 peakC = vec2(1.0, -1.0 * 4.0);\n"
"  vec3 hitMin = min(mn4, e) * (1.0 / max(4.0 * mx4, vec3(1e-8)));\n"
"  vec3 hitMax = (peakC.x - max(mx4, e)) *\n"
"                (1.0 / max(4.0 * mn4 + vec3(peakC.y), vec3(1e-8)));\n"
"  vec3 lobe = max(-hitMin, hitMax);\n"
"  float lobeF = max(-0.25, min(max(max(lobe.r, lobe.g), lobe.b), 0.0)) * uSharp;\n"
"  lobeF *= nz;\n"
"\n"
"  float rcpL = 1.0 / max(4.0 * lobeF + 1.0, 1e-8);\n"
"  vec3 pix = (lobeF * b + lobeF * d + lobeF * h + lobeF * f + e) * rcpL;\n"
"  fragColor = vec4(pix, 1.0);\n"
"}\n";

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
typedef struct {
    BOOL    resolved;       // GL 入口点已解析
    BOOL    dead;           // 出过致命错误，永久关闭
    BOOL    built;          // 资源已建
    BOOL    logged;         // 已打过一次启用日志

    int     surfaceW, surfaceH;   // EGL surface（全分辨率）
    int     renderW,  renderH;    // 渲染分辨率（低）

    ame_GLuint texLow;      // 渲染分辨率的拷贝
    ame_GLuint fboLow;
    ame_GLuint texHigh;     // EASU 输出
    ame_GLuint fboHigh;
    ame_GLuint vao, vbo;
    ame_GLuint progEasu, progRcas;
    ame_GLint  locEasuSrc, locEasuInput, locEasuOutput, locEasuCon0;
    ame_GLint  locRcasSrc, locRcasOutput, locRcasSharp;
} AmeFsr1State;

static AmeFsr1State g_s = {0};

static float ameFsr1Scale(void) {
    // 优先环境变量（便于 A/B，不用改设置），其次设置项。
    const char *env = getenv("AMETHYST_FSR1_SCALE");
    if (env != NULL && env[0] != '\0') {
        float v = (float)atof(env);
        if (v > 0.20f && v < 1.0f) return v;
    }
    float pct = getPrefFloat(@"video.resolution");
    if (!(pct > 20.0f)) return 1.0f;
    float v = pct / 100.0f;
    if (v >= 0.999f) return 1.0f;   // 100% 时没有可上采样的东西
    return v;
}

static BOOL ameFsr1Wanted(void) {
    if (g_s.dead) return NO;
    const char *env = getenv("AMETHYST_FSR1");
    if (env != NULL) {
        if (strcmp(env, "0") == 0) return NO;
        if (strcmp(env, "1") == 0) return YES;
    }
    return getPrefBool(@"video.fsr1");
}

static float ameFsr1SharpnessStops(void) {
    const char *env = getenv("AMETHYST_FSR1_SHARPNESS");
    if (env != NULL && env[0] != '\0') {
        float v = (float)atof(env);
        if (v >= 0.0f && v <= 2.0f) return v;
    }
    return 0.2f;   // FSR1 常用值
}

bool ameFsr1Active(void) {
    return (g_s.built && !g_s.dead && ameFsr1Wanted());
}

bool ameFsr1NeedsFullResSurface(void) {
    if (g_s.dead) return false;
    if (!ameFsr1Wanted()) return false;
    return (ameFsr1Scale() < 0.999f);
}

bool ameFsr1RenderSize(int surfaceW, int surfaceH, int *outW, int *outH) {
    if (outW == NULL || outH == NULL) return false;
    if (surfaceW <= 0 || surfaceH <= 0) { *outW = surfaceW; *outH = surfaceH; return false; }
    if (!ameFsr1Wanted() || g_s.dead) { *outW = surfaceW; *outH = surfaceH; return false; }
    float s = ameFsr1Scale();
    if (s >= 0.999f) { *outW = surfaceW; *outH = surfaceH; return false; }
    int w = (int)floorf((float)surfaceW * s + 0.5f);
    int h = (int)floorf((float)surfaceH * s + 0.5f);
    // 至少 2 像素，且不超过 surface
    if (w < 2) w = 2; if (h < 2) h = 2;
    if (w > surfaceW) w = surfaceW;
    if (h > surfaceH) h = surfaceH;
    *outW = w; *outH = h;
    return true;
}

// ---------------------------------------------------------------------------
// 资源
// ---------------------------------------------------------------------------
static void ameDrainErrors(void) {
    if (ame_glGetError == NULL) return;
    for (int i = 0; i < 8; i++) {
        if (ame_glGetError() == AME_GL_NO_ERROR) break;
    }
}

static ame_GLuint ameCompile(ame_GLenum type, const char *src) {
    ame_GLuint sh = ame_glCreateShader(type);
    if (sh == 0) return 0;
    ame_glShaderSource(sh, 1, &src, NULL);
    ame_glCompileShader(sh);
    ame_GLint ok = 0;
    ame_glGetShaderiv(sh, AME_GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        ame_GLsizei len = 0;
        log[0] = '\0';
        ame_glGetShaderInfoLog(sh, (ame_GLsizei)sizeof(log) - 1, &len, log);
        NSLog(@"[FSR1] shader compile failed: %s", log);
        ame_glDeleteShader(sh);
        return 0;
    }
    return sh;
}

static ame_GLuint ameLink(const char *vsrc, const char *fsrc) {
    ame_GLuint vs = ameCompile(AME_GL_VERTEX_SHADER, vsrc);
    if (vs == 0) return 0;
    ame_GLuint fs = ameCompile(AME_GL_FRAGMENT_SHADER, fsrc);
    if (fs == 0) { ame_glDeleteShader(vs); return 0; }
    ame_GLuint prog = ame_glCreateProgram();
    if (prog == 0) { ame_glDeleteShader(vs); ame_glDeleteShader(fs); return 0; }
    ame_glAttachShader(prog, vs);
    ame_glAttachShader(prog, fs);
    ame_glLinkProgram(prog);
    ame_glDeleteShader(vs);
    ame_glDeleteShader(fs);
    ame_GLint ok = 0;
    ame_glGetProgramiv(prog, AME_GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        ame_GLsizei len = 0;
        log[0] = '\0';
        ame_glGetProgramInfoLog(prog, (ame_GLsizei)sizeof(log) - 1, &len, log);
        NSLog(@"[FSR1] program link failed: %s", log);
        ame_glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

static void ameReleaseResources(void) {
    if (g_s.progEasu) { ame_glDeleteProgram(g_s.progEasu); g_s.progEasu = 0; }
    if (g_s.progRcas) { ame_glDeleteProgram(g_s.progRcas); g_s.progRcas = 0; }
    if (g_s.fboLow)   { ame_glDeleteFramebuffers(1, &g_s.fboLow);   g_s.fboLow = 0; }
    if (g_s.fboHigh)  { ame_glDeleteFramebuffers(1, &g_s.fboHigh);  g_s.fboHigh = 0; }
    if (g_s.texLow)   { ame_glDeleteTextures(1, &g_s.texLow);       g_s.texLow = 0; }
    if (g_s.texHigh)  { ame_glDeleteTextures(1, &g_s.texHigh);      g_s.texHigh = 0; }
    if (g_s.vbo)      { ame_glDeleteBuffers(1, &g_s.vbo);           g_s.vbo = 0; }
    if (g_s.vao)      { ame_glDeleteVertexArrays(1, &g_s.vao);      g_s.vao = 0; }
    g_s.built = NO;
}

static ame_GLuint ameMakeColorTexture(int w, int h) {
    ame_GLuint tex = 0;
    ame_glGenTextures(1, &tex);
    if (tex == 0) return 0;
    ame_glBindTexture(AME_GL_TEXTURE_2D, tex);
    ame_glTexImage2D(AME_GL_TEXTURE_2D, 0, (ame_GLint)AME_GL_RGBA8,
                     (ame_GLsizei)w, (ame_GLsizei)h, 0,
                     AME_GL_RGBA, AME_GL_UNSIGNED_BYTE, NULL);
    ame_glTexParameteri(AME_GL_TEXTURE_2D, AME_GL_TEXTURE_MIN_FILTER, AME_GL_LINEAR);
    ame_glTexParameteri(AME_GL_TEXTURE_2D, AME_GL_TEXTURE_MAG_FILTER, AME_GL_LINEAR);
    ame_glTexParameteri(AME_GL_TEXTURE_2D, AME_GL_TEXTURE_WRAP_S, AME_GL_CLAMP_TO_EDGE);
    ame_glTexParameteri(AME_GL_TEXTURE_2D, AME_GL_TEXTURE_WRAP_T, AME_GL_CLAMP_TO_EDGE);
    ame_glTexParameteri(AME_GL_TEXTURE_2D, AME_GL_TEXTURE_MAX_LEVEL, 0);
    return tex;
}

static BOOL ameBuild(int surfaceW, int surfaceH, int renderW, int renderH) {
    ameReleaseResources();
    ameDrainErrors();

    g_s.surfaceW = surfaceW; g_s.surfaceH = surfaceH;
    g_s.renderW  = renderW;  g_s.renderH  = renderH;

    g_s.progEasu = ameLink(kFSRVert, kFSRFragEASU);
    if (g_s.progEasu == 0) return NO;
    g_s.locEasuSrc    = ame_glGetUniformLocation(g_s.progEasu, "uSrc");
    g_s.locEasuInput  = ame_glGetUniformLocation(g_s.progEasu, "uInputSize");
    g_s.locEasuOutput = ame_glGetUniformLocation(g_s.progEasu, "uOutputSize");
    g_s.locEasuCon0   = ame_glGetUniformLocation(g_s.progEasu, "uCon0");

    g_s.progRcas = ameLink(kFSRVert, kFSRFragRCAS);
    if (g_s.progRcas == 0) return NO;
    g_s.locRcasSrc    = ame_glGetUniformLocation(g_s.progRcas, "uSrc");
    g_s.locRcasOutput = ame_glGetUniformLocation(g_s.progRcas, "uOutputSize");
    g_s.locRcasSharp  = ame_glGetUniformLocation(g_s.progRcas, "uSharp");

    // 全屏三角形
    static const float kQuad[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    ame_glGenVertexArrays(1, &g_s.vao);
    ame_glGenBuffers(1, &g_s.vbo);
    if (g_s.vao == 0 || g_s.vbo == 0) return NO;
    ame_glBindVertexArray(g_s.vao);
    ame_glBindBuffer(AME_GL_ARRAY_BUFFER, g_s.vbo);
    ame_glBufferData(AME_GL_ARRAY_BUFFER, (long)sizeof(kQuad), kQuad, AME_GL_STATIC_DRAW);
    ame_glVertexAttribPointer(0, 2, AME_GL_FLOAT, 0, (ame_GLsizei)(2 * sizeof(float)), (const void *)0);
    ame_glEnableVertexAttribArray(0);
    ame_glBindBuffer(AME_GL_ARRAY_BUFFER, 0);
    ame_glBindVertexArray(0);

    g_s.texLow = ameMakeColorTexture(renderW, renderH);
    if (g_s.texLow == 0) return NO;
    ame_glGenFramebuffers(1, &g_s.fboLow);
    if (g_s.fboLow == 0) return NO;
    ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, g_s.fboLow);
    ame_glFramebufferTexture2D(AME_GL_FRAMEBUFFER, AME_GL_COLOR_ATTACHMENT0,
                               AME_GL_TEXTURE_2D, g_s.texLow, 0);
    if (ame_glCheckFramebufferStatus(AME_GL_FRAMEBUFFER) != AME_GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[FSR1] render-resolution FBO incomplete");
        return NO;
    }

    g_s.texHigh = ameMakeColorTexture(surfaceW, surfaceH);
    if (g_s.texHigh == 0) return NO;
    ame_glGenFramebuffers(1, &g_s.fboHigh);
    if (g_s.fboHigh == 0) return NO;
    ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, g_s.fboHigh);
    ame_glFramebufferTexture2D(AME_GL_FRAMEBUFFER, AME_GL_COLOR_ATTACHMENT0,
                               AME_GL_TEXTURE_2D, g_s.texHigh, 0);
    if (ame_glCheckFramebufferStatus(AME_GL_FRAMEBUFFER) != AME_GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"[FSR1] surface-resolution FBO incomplete");
        return NO;
    }

    // sampler 绑定是 program 状态，设一次即可
    ame_glUseProgram(g_s.progEasu);
    if (g_s.locEasuSrc >= 0) ame_glUniform1i(g_s.locEasuSrc, 0);
    ame_glUseProgram(g_s.progRcas);
    if (g_s.locRcasSrc >= 0) ame_glUniform1i(g_s.locRcasSrc, 0);
    ame_glUseProgram(0);

    ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, 0);
    ameDrainErrors();
    g_s.built = YES;
    return YES;
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------
void ameFsr1Present(int surfaceW, int surfaceH) {
    if (surfaceW <= 0 || surfaceH <= 0) return;
    if (g_s.dead) return;
    if (!ameFsr1Wanted()) return;

    if (!g_s.resolved) {
        if (!ameResolveAll()) {
            // 渲染器可能还没载入，下一帧再试；但至少留一条可诊断的痕迹，
            // 免得"完全无效果"却连一行日志都没有（本次排查的最大障碍）。
            if (!g_unresolvedLogged) {
                g_unresolvedLogged = YES;
                NSLog(@"[FSR1] inactive: GL entry points unresolved (renderer not loaded yet?)");
            }
            return;
        }
        g_s.resolved = YES;
        g_unresolvedLogged = NO;
    }

    // 源区域取 MC 当前的实际 viewport，而不是按 scale 算出的理论渲染尺寸：
    // MC 可能因分辨率设置、SDL 点/像素口径差异、隐藏工具窗口等原因使用别的值，
    // 按实际值自适应最稳 —— 只要它在左下角且小于 surface 就是有效的输入。
    ame_GLint vp0[4] = {0, 0, 0, 0};
    ame_glGetIntegerv(AME_GL_VIEWPORT, vp0);
    int srcW = vp0[2], srcH = vp0[3];
    if (srcW < 2 || srcH < 2) return;
    if (srcW > surfaceW) srcW = surfaceW;
    if (srcH > surfaceH) srcH = surfaceH;
    if (srcW >= surfaceW && srcH >= surfaceH) {
        // 常见成因：video.resolution 仍是 100%（没有可上采样的东西），
        // 或 MC 的 viewport 已被别处纠正成 surface 尺寸。留一次日志。
        if (!g_idleLogged) {
            g_idleLogged = YES;
            NSLog(@"[FSR1] idle: viewport %dx%d == surface %dx%d (nothing to upscale; "
                  @"set Resolution below 100%%)", srcW, srcH, surfaceW, surfaceH);
        }
        return;   // 未缩放，无需上采样
    }
    g_idleLogged = NO;

    if (!g_s.built ||
        g_s.surfaceW != surfaceW || g_s.surfaceH != surfaceH ||
        g_s.renderW  != srcW     || g_s.renderH  != srcH) {
        if (!ameBuild(surfaceW, surfaceH, srcW, srcH)) {
            NSLog(@"[FSR1] disabled: resource setup failed");
            g_s.dead = YES;
            ameReleaseResources();
            return;
        }
        if (!g_s.logged) {
            g_s.logged = YES;
            NSLog(@"[FSR1] active: render %dx%d -> surface %dx%d (scale %.2f, sharp %.2f)",
                  srcW, srcH, surfaceW, surfaceH,
                  (float)srcW / (float)surfaceW, ameFsr1SharpnessStops());
        }
    }

    // —— 保存会被本函数改写的 GL 状态 ——
    ame_GLint prevVp[4] = {0, 0, 0, 0};
    ame_GLint prevFbo = 0, prevReadFbo = 0, prevDrawFbo = 0;
    ame_GLint prevProg = 0, prevVao = 0, prevArrayBuf = 0;
    ame_GLint prevActiveTex = AME_GL_TEXTURE0, prevTex2D = 0;
    ame_glGetIntegerv(AME_GL_VIEWPORT, prevVp);
    ame_glGetIntegerv(AME_GL_FRAMEBUFFER_BINDING, &prevFbo);
    ame_glGetIntegerv(AME_GL_VERTEX_ARRAY_BINDING, &prevVao);
    ame_glGetIntegerv(AME_GL_ARRAY_BUFFER_BINDING, &prevArrayBuf);
    ame_glGetIntegerv(AME_GL_CURRENT_PROGRAM, &prevProg);
    ame_glGetIntegerv(AME_GL_ACTIVE_TEXTURE, &prevActiveTex);
    ame_glActiveTexture(AME_GL_TEXTURE0);
    ame_glGetIntegerv(AME_GL_TEXTURE_BINDING_2D, &prevTex2D);
    prevReadFbo = prevFbo; prevDrawFbo = prevFbo;

    ame_GLint prevSamples = 0;
    ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, 0);
    ame_glGetIntegerv(AME_GL_SAMPLES, &prevSamples);

    ame_glDisable(AME_GL_BLEND);
    ame_glDisable(AME_GL_DEPTH_TEST);
    ame_glDisable(AME_GL_STENCIL_TEST);
    ame_glDisable(AME_GL_CULL_FACE);
    ame_glDisable(AME_GL_SCISSOR_TEST);
    ame_glPixelStorei(AME_GL_UNPACK_ALIGNMENT, 1);

    // —— 1) 把 framebuffer 0 左下角的渲染区域拷到低分辨率纹理 ——
    // 多重采样的 window surface 无法做缩放 blit（GLES 规范：src/dst 尺寸不同
    // 且 src 是多重采样时非法）。与其留下 INVALID_OPERATION 让画面停在半截，
    // 不如直接关闭 FSR1。
    BOOL aborted = NO;

    if (prevSamples > 1) {
        NSLog(@"[FSR1] disabled: window surface is multisampled (samples=%d)", prevSamples);
        g_s.dead = YES;
        ameReleaseResources();
        aborted = YES;
    }

    if (!aborted) {
        ame_glBindFramebuffer(AME_GL_READ_FRAMEBUFFER, 0);
        ame_glBindFramebuffer(AME_GL_DRAW_FRAMEBUFFER, g_s.fboLow);
        ame_glBlitFramebuffer(0, 0, srcW, srcH,
                              0, 0, srcW, srcH,
                              AME_GL_COLOR_BUFFER_BIT, AME_GL_NEAREST);

        if (ame_glGetError() != AME_GL_NO_ERROR) {
            NSLog(@"[FSR1] disabled: blit to render-resolution target failed");
            g_s.dead = YES;
            ameReleaseResources();
            aborted = YES;
        }
    }

    // —— 2) EASU：低分辨率 -> 全分辨率 ——
    if (!aborted) {
        float con0x = (float)srcW  / (float)surfaceW;
        float con0y = (float)srcH  / (float)surfaceH;
        float con0z = 0.5f * con0x - 0.5f;
        float con0w = 0.5f * con0y - 0.5f;

        ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, g_s.fboHigh);
        ame_glViewport(0, 0, surfaceW, surfaceH);
        ame_glUseProgram(g_s.progEasu);
        ame_glActiveTexture(AME_GL_TEXTURE0);
        ame_glBindTexture(AME_GL_TEXTURE_2D, g_s.texLow);
        if (g_s.locEasuInput  >= 0) ame_glUniform2f(g_s.locEasuInput,  (float)srcW,  (float)srcH);
        if (g_s.locEasuOutput >= 0) ame_glUniform2f(g_s.locEasuOutput, (float)surfaceW, (float)surfaceH);
        if (g_s.locEasuCon0   >= 0) ame_glUniform4f(g_s.locEasuCon0, con0x, con0y, con0z, con0w);
        ame_glBindVertexArray(g_s.vao);
        ame_glDrawArrays(AME_GL_TRIANGLES, 0, 3);
    }

    // —— 3) RCAS：锐化，输出到 framebuffer 0 ——
    if (!aborted) {
        ame_glBindFramebuffer(AME_GL_FRAMEBUFFER, 0);
        ame_glViewport(0, 0, surfaceW, surfaceH);
        ame_glUseProgram(g_s.progRcas);
        ame_glActiveTexture(AME_GL_TEXTURE0);
        ame_glBindTexture(AME_GL_TEXTURE_2D, g_s.texHigh);
        if (g_s.locRcasOutput >= 0) ame_glUniform2f(g_s.locRcasOutput, (float)surfaceW, (float)surfaceH);
        if (g_s.locRcasSharp  >= 0) {
            float stops = ameFsr1SharpnessStops();
            ame_glUniform1f(g_s.locRcasSharp, exp2f(-stops));
        }
        ame_glBindVertexArray(g_s.vao);
        ame_glDrawArrays(AME_GL_TRIANGLES, 0, 3);
    }

    // 出错就自我关闭，绝不停在半截状态
    if (!aborted && ame_glGetError() != AME_GL_NO_ERROR) {
        NSLog(@"[FSR1] disabled: GL error during upscale pass");
        g_s.dead = YES;
        ameReleaseResources();
    }

    // —— 恢复 GL 状态 ——
    ame_glBindVertexArray((ame_GLuint)prevVao);
    ame_glBindBuffer(AME_GL_ARRAY_BUFFER, (ame_GLuint)prevArrayBuf);
    ame_glActiveTexture(AME_GL_TEXTURE0);
    ame_glBindTexture(AME_GL_TEXTURE_2D, (ame_GLuint)prevTex2D);
    ame_glActiveTexture((ame_GLenum)prevActiveTex);
    ame_glUseProgram((ame_GLuint)prevProg);
    ame_glBindFramebuffer(AME_GL_READ_FRAMEBUFFER, (ame_GLuint)prevReadFbo);
    ame_glBindFramebuffer(AME_GL_DRAW_FRAMEBUFFER, (ame_GLuint)prevDrawFbo);
    ame_glViewport(prevVp[0], prevVp[1], prevVp[2], prevVp[3]);
    // FSR1 自我关闭后，MC 下一帧仍会按低分辨率 viewport 画；此处留的是恢复值，
    // viewport 守护会在 swap 时把它对齐到 surface（ameFsr1RenderSize 已返回假）。
}

void ameFsr1DumpState(void) {
    NSLog(@"[FSR1] state: wanted=%d resolved=%d built=%d dead=%d "
          @"surface=%dx%d render=%dx%d",
          (int)ameFsr1Wanted(), (int)g_s.resolved, (int)g_s.built, (int)g_s.dead,
          g_s.surfaceW, g_s.surfaceH, g_s.renderW, g_s.renderH);
}
