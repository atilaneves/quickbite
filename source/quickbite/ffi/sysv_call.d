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
    public bool usesAvx;
    public ubyte stackAlignment;
    private ubyte[4] _padding;
    public ulong[6] gpr;
    public ubyte[32][8] vector;
    public ulong[2] resultGpr;
    public ubyte[32][2] resultVector;
    public ubyte[16] resultX87;
}


static assert(SysVCallFrame.stackAddress.offsetof == 8);
static assert(SysVCallFrame.stackSize.offsetof == 16);
static assert(SysVCallFrame.sseCount.offsetof == 24);
static assert(SysVCallFrame.resultKind.offsetof == 25);
static assert(SysVCallFrame.usesAvx.offsetof == 26);
static assert(SysVCallFrame.stackAlignment.offsetof == 27);
static assert(SysVCallFrame.gpr.offsetof == 32);
static assert(SysVCallFrame.vector.offsetof == 80);
static assert(SysVCallFrame.resultGpr.offsetof == 336);
static assert(SysVCallFrame.resultVector.offsetof == 352);
static assert(SysVCallFrame.resultX87.offsetof == 416);


public extern(C) void invokeSysV(SysVCallFrame* frame) {
    asm {
        mov R12, frame;
        mov R13, RSP;

        cmp byte ptr [R12 + 27], 32;
        jne stackAligned;
        and RSP, -32;
    stackAligned:
        mov RCX, [R12 + 16];
        test RCX, RCX;
        jz stackCopied;
        sub RSP, RCX;
        mov RDI, RSP;
        mov RSI, [R12 + 8];
        rep;
        movsb;
    stackCopied:

        cmp byte ptr [R12 + 26], 0;
        jne loadYmm;
        movdqu XMM0, [R12 + 80];
        movdqu XMM1, [R12 + 112];
        movdqu XMM2, [R12 + 144];
        movdqu XMM3, [R12 + 176];
        movdqu XMM4, [R12 + 208];
        movdqu XMM5, [R12 + 240];
        movdqu XMM6, [R12 + 272];
        movdqu XMM7, [R12 + 304];
        jmp vectorsLoaded;
    loadYmm:
        db 0xC4, 0xC1, 0x7E, 0x6F, 0x44, 0x24, 0x50;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0x4C, 0x24, 0x70;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0x94, 0x24, 0x90, 0, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0x9C, 0x24, 0xB0, 0, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0xA4, 0x24, 0xD0, 0, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0xAC, 0x24, 0xF0, 0, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0xB4, 0x24, 0x10, 1, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x6F, 0xBC, 0x24, 0x30, 1, 0, 0;
    vectorsLoaded:
        mov RDI, [R12 + 32];
        mov RSI, [R12 + 40];
        mov RDX, [R12 + 48];
        mov RCX, [R12 + 56];
        mov R8, [R12 + 64];
        mov R9, [R12 + 72];
        mov R11, [R12];
        mov AL, [R12 + 24];
        call R11;

        mov [R12 + 336], RAX;
        mov [R12 + 344], RDX;
        cmp byte ptr [R12 + 26], 0;
        jne storeYmm;
        movdqu [R12 + 352], XMM0;
        movdqu [R12 + 384], XMM1;
        jmp vectorsStored;
    storeYmm:
        db 0xC4, 0xC1, 0x7E, 0x7F, 0x84, 0x24, 0x60, 1, 0, 0;
        db 0xC4, 0xC1, 0x7E, 0x7F, 0x8C, 0x24, 0x80, 1, 0, 0;
        db 0xC5, 0xF8, 0x77;
    vectorsStored:
        cmp byte ptr [R12 + 25], SysVResultKind.x87;
        jne resultStored;
        fstp real ptr [R12 + 416];
    resultStored:
        mov RSP, R13;
    }
}
