// Test of the AArch64 C++ UNO bridge's assembler code and calling
// conventions, against code GCC compiles for real virtual calls.
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <stdexcept>
#include <sys/mman.h>

typedef uint64_t u64;
extern "C" void callVirtualMethodImpl(void *, u64 *, u64 *, u64 *, u64, void *, u64 *);
extern "C" void privateSnippetExecutor(...);

static int fails = 0, checks = 0;
#define CHECK(c) do { ++checks; if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); ++fails; } } while (0)

struct P2i { int32_t x, y; };            // in x0
struct R4i { int32_t a, b, c, d; };      // in x0, x1
struct D2 { double x, y; };              // HFA: d0, d1
struct F3 { float a, b, c; };            // HFA: s0, s1, s2
struct Big { int64_t a, b, c; };         // memory, x8
struct Str { std::string s; };           // non-trivial: memory, x8

struct Iface {
    virtual void dummy0() {}
    virtual int64_t mixed(int8_t a, int16_t b, int32_t c, int64_t d, float e, double f,
                          uint16_t g, bool h, int32_t i, double j, float k, int64_t l,
                          double m, double n, double o, double p, double q, float r,
                          int32_t s, double t) = 0;
    virtual float retFloat(float a) = 0;
    virtual double retDouble(double a, int x) = 0;
    virtual P2i retP2i(int x) = 0;
    virtual R4i retR4i(int x) = 0;
    virtual D2 retD2(double x) = 0;
    virtual F3 retF3(float x) = 0;
    virtual Big retBig(int64_t x) = 0;
    virtual Str retStr(const char * x) = 0;
    virtual int thrower(int x) = 0;
    virtual bool retBool(int x) = 0;
};

// ---------------------------------------------------------------------
// 1. uno2cpp direction: callVirtualMethodImpl calling a C++ object.

static int8_t ga; static int16_t gb; static int32_t gc, gi, gs; static int64_t gd, gl;
static float ge, gk, gr; static double gf, gj, gm, gn, go, gp, gq, gt; static uint16_t gg; static bool gh;

struct Impl : Iface {
    int64_t mixed(int8_t a, int16_t b, int32_t c, int64_t d, float e, double f,
                  uint16_t g, bool h, int32_t i, double j, float k, int64_t l,
                  double m, double n, double o, double p, double q, float r,
                  int32_t s, double t) override {
        ga=a; gb=b; gc=c; gd=d; ge=e; gf=f; gg=g; gh=h; gi=i; gj=j; gk=k; gl=l;
        gm=m; gn=n; go=o; gp=p; gq=q; gr=r; gs=s; gt=t;
        return 0x1122334455667788LL;
    }
    float retFloat(float a) override { return a * 2; }
    double retDouble(double a, int x) override { return a + x; }
    P2i retP2i(int x) override { return P2i{ x, -x }; }
    R4i retR4i(int x) override { return R4i{ x, x+1, x+2, x+3 }; }
    D2 retD2(double x) override { return D2{ x, x*3 }; }
    F3 retF3(float x) override { return F3{ x, x+1, x+2 }; }
    Big retBig(int64_t x) override { return Big{ x, x*2, x*3 }; }
    Str retStr(const char * x) override { return Str{ std::string(x) + "!" }; }
    int thrower(int x) override { throw std::runtime_error(std::to_string(x)); }
    bool retBool(int x) override { return x > 0; }
};

// The marshalling uno2cpp.cxx does.
struct Call {
    u64 gpr[8] = {}, fpr[8] = {}, stack[32] = {}; unsigned ng = 0, nf = 0, ns = 0;
    void i(u64 v) { if (ng < 8) gpr[ng++] = v; else stack[ns++] = v; }
    void f(float v) { u64 b = 0; memcpy(&b, &v, 4); if (nf < 8) fpr[nf++] = b; else stack[ns++] = b; }
    void d(double v) { u64 b; memcpy(&b, &v, 8); if (nf < 8) fpr[nf++] = b; else stack[ns++] = b; }
};

static int slot(void * obj, void (Iface::*)()) { return 0; }

static void test_uno2cpp()
{
    Impl impl; Iface * p = &impl; u64 ret[6];
    // vtable indices: dummy0=0, mixed=1, retFloat=2, retDouble=3, retP2i=4,
    // retR4i=5, retD2=6, retF3=7, retBig=8, retStr=9, thrower=10, retBool=11
    void ** vt = *reinterpret_cast<void ***>(p);

    { Call c; c.i((u64)p);
      c.i((u64)(int64_t)(int8_t)-5); c.i((u64)(int64_t)(int16_t)-300); c.i((u64)(int64_t)-70000);
      c.i((u64)-9000000000LL); c.f(1.5f); c.d(2.25); c.i(65000); c.i(1); c.i((u64)(int64_t)-7);
      c.d(3.5); c.f(4.75f); c.i(123456789012LL); c.d(5.5); c.d(6.5); c.d(7.5); c.d(8.5);
      c.d(9.5); c.f(10.25f) /* 9th fp: stack */; c.i((u64)(int64_t)-42) /* 9th int: stack */;
      c.d(11.125) /* stack */;
      callVirtualMethodImpl(vt[1], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      CHECK((int64_t)ret[0] == 0x1122334455667788LL);
      CHECK(ga==-5); CHECK(gb==-300); CHECK(gc==-70000); CHECK(gd==-9000000000LL);
      CHECK(ge==1.5f); CHECK(gf==2.25); CHECK(gg==65000); CHECK(gh==true); CHECK(gi==-7);
      CHECK(gj==3.5); CHECK(gk==4.75f); CHECK(gl==123456789012LL); CHECK(gm==5.5); CHECK(gn==6.5);
      CHECK(go==7.5); CHECK(gp==8.5); CHECK(gq==9.5); CHECK(gr==10.25f); CHECK(gs==-42); CHECK(gt==11.125);
      CHECK(c.ns == 5); /* l, s: 9th, 10th int; q, r, t: 9th-11th fp */ }

    { Call c; c.i((u64)p); c.f(3.25f); callVirtualMethodImpl(vt[2], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      float r; memcpy(&r, &ret[2], 4); CHECK(r == 6.5f); }
    { Call c; c.i((u64)p); c.d(1.5); c.i(2); callVirtualMethodImpl(vt[3], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      double r; memcpy(&r, &ret[2], 8); CHECK(r == 3.5); }
    { Call c; c.i((u64)p); c.i(7); callVirtualMethodImpl(vt[4], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      P2i r; memcpy(&r, ret, 8); CHECK(r.x == 7 && r.y == -7); }
    { Call c; c.i((u64)p); c.i(10); callVirtualMethodImpl(vt[5], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      R4i r; memcpy(&r, ret, 16); CHECK(r.a==10 && r.b==11 && r.c==12 && r.d==13); }
    { Call c; c.i((u64)p); c.d(2.0); callVirtualMethodImpl(vt[6], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      double a, b; memcpy(&a, &ret[2], 8); memcpy(&b, &ret[3], 8); CHECK(a == 2.0 && b == 6.0); }
    { Call c; c.i((u64)p); c.f(1.0f); callVirtualMethodImpl(vt[7], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      float a, b, d; memcpy(&a, &ret[2], 4); memcpy(&b, &ret[3], 4); memcpy(&d, &ret[4], 4);
      CHECK(a == 1.0f && b == 2.0f && d == 3.0f); }
    { Big big = {}; Call c; c.i((u64)p); c.i(5); callVirtualMethodImpl(vt[8], c.gpr, c.fpr, c.stack, c.ns, &big, ret);
      CHECK(big.a == 5 && big.b == 10 && big.c == 15); }
    { alignas(Str) char buf[sizeof(Str)]; Call c; c.i((u64)p); c.i((u64)"abc");
      callVirtualMethodImpl(vt[9], c.gpr, c.fpr, c.stack, c.ns, buf, ret);
      Str * s = reinterpret_cast<Str *>(buf); CHECK(s->s == "abc!"); s->~Str(); }
    { Call c; c.i((u64)p); c.i(99); bool caught = false;
      try { callVirtualMethodImpl(vt[10], c.gpr, c.fpr, c.stack, c.ns, 0, ret); }
      catch (std::runtime_error & e) { caught = std::string(e.what()) == "99"; }
      CHECK(caught); }
    { Call c; c.i((u64)p); c.i(3); callVirtualMethodImpl(vt[11], c.gpr, c.fpr, c.stack, c.ns, 0, ret);
      CHECK((ret[0] & 0xff) == 1); }
}

// ---------------------------------------------------------------------
// 2. cpp2uno direction: C++ calls through a vtable of generated snippets
// into privateSnippetExecutor and cpp_vtable_call.

static unsigned char * codeSnippet(unsigned char * code, int32_t nFunctionIndex, int32_t nVtableOffset)
{   // as cpp2uno.cxx
    u64 nOffsetAndIndex = (((u64)nVtableOffset) << 32) | (u64)(uint32_t)nFunctionIndex;
    uint32_t * p = reinterpret_cast<uint32_t *>(code);
    p[0] = 0x58000089; p[1] = 0x580000aa; p[2] = 0xd61f0140; p[3] = 0xd503201f;
    *reinterpret_cast<u64 *>(code + 16) = nOffsetAndIndex;
    *reinterpret_cast<u64 *>(code + 24) = reinterpret_cast<u64>(privateSnippetExecutor);
    return code + 32;
}

static void * gThis; static int gIndex, gOffset; static void ** gGpr; static void ** gFpr; static void ** gOvr; static void * gInd;

extern "C" int cpp_vtable_call(int32_t idx, int32_t off, void ** gpreg, void ** fpreg, void ** ovrflw,
                               u64 * ret, void * indirect)
{
    gIndex = idx; gOffset = off; gGpr = gpreg; gFpr = fpreg; gOvr = ovrflw; gInd = indirect;
    memset(ret, 0, 48);
    switch (idx) {
    case 1: { // mixed: check all twenty arguments where cpp2uno.cxx looks for them
        void ** g = gpreg + 1; void ** f = fpreg; void ** o = ovrflw; unsigned ng = 1, nf = 0;
        auto I = [&]() -> void * { return ng++ < 8 ? (void *)g++ : (void *)o++; };
        auto F = [&]() -> void * { return nf++ < 8 ? (void *)f++ : (void *)o++; };
        CHECK(*(int8_t *)I() == -5); CHECK(*(int16_t *)I() == -300); CHECK(*(int32_t *)I() == -70000);
        CHECK(*(int64_t *)I() == -9000000000LL); CHECK(*(float *)F() == 1.5f); CHECK(*(double *)F() == 2.25);
        CHECK(*(uint16_t *)I() == 65000); CHECK(*(bool *)I() == true); CHECK(*(int32_t *)I() == -7);
        CHECK(*(double *)F() == 3.5); CHECK(*(float *)F() == 4.75f); CHECK(*(int64_t *)I() == 123456789012LL);
        CHECK(*(double *)F() == 5.5); CHECK(*(double *)F() == 6.5); CHECK(*(double *)F() == 7.5);
        CHECK(*(double *)F() == 8.5); CHECK(*(double *)F() == 9.5); CHECK(*(float *)F() == 10.25f);
        CHECK(*(int32_t *)I() == -42); CHECK(*(double *)F() == 11.125);
        ret[0] = 0x1122334455667788ULL; break; }
    case 2: { float a = *(float *)&fpreg[0] * 2; memcpy(&ret[2], &a, 4); break; }
    case 3: { double a = *(double *)&fpreg[0] + *(int32_t *)&gpreg[1]; memcpy(&ret[2], &a, 8); break; }
    case 4: { int32_t x = *(int32_t *)&gpreg[1]; P2i r{ x, -x }; memcpy(ret, &r, 8); break; }
    case 5: { int32_t x = *(int32_t *)&gpreg[1]; R4i r{ x, x+1, x+2, x+3 }; memcpy(ret, &r, 16); break; }
    case 6: { double x = *(double *)&fpreg[0]; double y = x*3; memcpy(&ret[2], &x, 8); memcpy(&ret[3], &y, 8); break; }
    case 7: { float x = *(float *)&fpreg[0]; float y = x+1, z = x+2;
              memcpy(&ret[2], &x, 4); memcpy(&ret[3], &y, 4); memcpy(&ret[4], &z, 4); break; }
    case 8: { int64_t x = *(int64_t *)&gpreg[1]; *(Big *)indirect = Big{ x, x*2, x*3 }; ret[0] = (u64)indirect; break; }
    case 9: { new (indirect) Str{ std::string(*(const char **)&gpreg[1]) + "!" }; ret[0] = (u64)indirect; break; }
    case 10: throw std::runtime_error("from cpp_vtable_call");
    case 11: ret[0] = *(int32_t *)&gpreg[1] > 0; break;
    }
    return 0;
}

static void test_cpp2uno()
{
    // Like the bridge's vtable block: offset-to-top, RTTI, then the slots;
    // the code snippets in executable memory.
    unsigned char * code = (unsigned char *)mmap(0, 4096, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    void * vtbl[2 + 12]; vtbl[0] = 0; vtbl[1] = 0;
    unsigned char * c = code;
    for (int k = 0; k < 12; ++k) { vtbl[2 + k] = c; c = codeSnippet(c, k, 0); }
    __builtin___clear_cache((char *)code, (char *)c);
    struct Obj { void ** vptr; } obj = { vtbl + 2 };
    Iface * p = reinterpret_cast<Iface *>(&obj);

    CHECK(p->mixed(-5, -300, -70000, -9000000000LL, 1.5f, 2.25, 65000, true, -7, 3.5, 4.75f,
                   123456789012LL, 5.5, 6.5, 7.5, 8.5, 9.5, 10.25f, -42, 11.125) == 0x1122334455667788LL);
    CHECK(gIndex == 1 && gOffset == 0 && gGpr[0] == (void *)&obj);
    CHECK(p->retFloat(3.25f) == 6.5f);
    CHECK(p->retDouble(1.5, 2) == 3.5);
    { P2i r = p->retP2i(7); CHECK(r.x == 7 && r.y == -7); }
    { R4i r = p->retR4i(10); CHECK(r.a==10 && r.b==11 && r.c==12 && r.d==13); }
    { D2 r = p->retD2(2.0); CHECK(r.x == 2.0 && r.y == 6.0); }
    { F3 r = p->retF3(1.0f); CHECK(r.a == 1.0f && r.b == 2.0f && r.c == 3.0f); }
    { Big r = p->retBig(5); CHECK(r.a == 5 && r.b == 10 && r.c == 15); CHECK(gGpr[0] == (void *)&obj); }
    { Str r = p->retStr("xyz"); CHECK(r.s == "xyz!"); }
    { bool caught = false;
      try { p->thrower(1); } catch (std::runtime_error & e) { caught = std::string(e.what()) == "from cpp_vtable_call"; }
      CHECK(caught); }
    CHECK(p->retBool(4) == true); CHECK(p->retBool(-4) == false);
    // A this-adjusting call: snippet with vtable offset 16.
    { unsigned char * c2 = c; codeSnippet(c2, 4, 16); __builtin___clear_cache((char *)c2, (char *)c2 + 32);
      typedef P2i (*Fn)(void *, int); P2i r = ((Fn)c2)((char *)&obj + 16, 9);
      CHECK(gOffset == 16 && r.x == 9 && r.y == -9); }
}

int main()
{
    test_uno2cpp();
    test_cpp2uno();
    printf("%d checks, %d failures\n", checks, fails);
    return fails != 0;
}
