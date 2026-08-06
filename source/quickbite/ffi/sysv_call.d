module quickbite.ffi.sysv_call;

private:


public enum SysVResultKind : ubyte {
    none,
    registers,
    x87,
}


public struct SysVCallFrame {
    public void* target;
    public void* stackAddress;
    public size_t stackSize;
    public ubyte sseCount;
    public SysVResultKind resultKind;
    private ubyte[6] _padding;
    public ulong[6] gpr;
    public ubyte[16][8] xmm;
    public ulong[2] resultGpr;
    public ubyte[16][2] resultXmm;
    public ubyte[16] resultX87;
}


static assert(SysVCallFrame.stackAddress.offsetof == 8);
static assert(SysVCallFrame.stackSize.offsetof == 16);
static assert(SysVCallFrame.sseCount.offsetof == 24);
static assert(SysVCallFrame.resultKind.offsetof == 25);
static assert(SysVCallFrame.gpr.offsetof == 32);
static assert(SysVCallFrame.xmm.offsetof == 80);
static assert(SysVCallFrame.resultGpr.offsetof == 208);
static assert(SysVCallFrame.resultXmm.offsetof == 224);
static assert(SysVCallFrame.resultX87.offsetof == 256);


public extern(C) void invokeSysV(SysVCallFrame* frame) {
    asm {
        mov R12, frame;
        mov R13, RSP;

        mov RCX, [R12 + 16];
        test RCX, RCX;
        jz stackCopied;
        sub RSP, RCX;
        mov RDI, RSP;
        mov RSI, [R12 + 8];
        rep;
        movsb;
    stackCopied:

        movdqu XMM0, [R12 + 80];
        movdqu XMM1, [R12 + 96];
        movdqu XMM2, [R12 + 112];
        movdqu XMM3, [R12 + 128];
        movdqu XMM4, [R12 + 144];
        movdqu XMM5, [R12 + 160];
        movdqu XMM6, [R12 + 176];
        movdqu XMM7, [R12 + 192];
        mov RDI, [R12 + 32];
        mov RSI, [R12 + 40];
        mov RDX, [R12 + 48];
        mov RCX, [R12 + 56];
        mov R8, [R12 + 64];
        mov R9, [R12 + 72];
        mov R11, [R12];
        mov AL, [R12 + 24];
        call R11;

        mov [R12 + 208], RAX;
        mov [R12 + 216], RDX;
        movdqu [R12 + 224], XMM0;
        movdqu [R12 + 240], XMM1;
        cmp byte ptr [R12 + 25], SysVResultKind.x87;
        jne resultStored;
        fstp real ptr [R12 + 256];
    resultStored:
        mov RSP, R13;
    }
}
