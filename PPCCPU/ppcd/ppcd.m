// Very accurate PowerPC Architecture disassembler (both 32 and 64-bit instructions are supported)

// Branch Target in output parameters is NOT relative. Its already precalculated
// from effective address of current instruction.

// Note, that old mnemonics and operands will be overwritten, after next disasm
// call. So dont forget to copy them away, if supposed to use them lately.

// Instruction class can be combined from many flags. There can exist, for example,
// "FPU" + "LDST" instruction, except "ILLEGAL", which cannot be combined.

// RLWINM-like instructions mask is placed in output "target" parameter.

#include <stdio.h>
#include <string.h>

#include "CommonDefs.h"
#include "ppcd.h"
#include "../PPCCPU.h"

#define POWERPC_32      // Use generic 32-bit model
//efine POWERPC_64      // Use generic 64-bit model
#define GEKKO           // Use Gekko (32-bit ISA)
#define BROADWAY        // Use Broadway (32-bit ISA)

#define SIMPLIFIED      // Allow simplified mnemonics
//efine UPPERCASE       // Use upper case strings in output
#define COMMA   ", "
#define LPAREN  " ("
#define RPAREN  ")"
#define HEX1    "0x"    // prefix
#define HEX2    ""      // suffix

static int bigendian = -1;  // Autodetect.

// ---------------------------------------------------------------------------
// Implementation. Look away, code is messed :)
// Dont miss 'l' and '1'.

static PPCD_CB *o;
#define Instr   (o->instr)
#define DIS_PC  (o->pc)

// Simple decoder
#define DIS_RD      ((Instr >> 21) & 0x1f)
#define DIS_RS      DIS_RD
#define DIS_RA      ((Instr >> 16) & 0x1f)
#define DIS_RB      ((Instr >> 11) & 0x1f)
#define DIS_RC      ((Instr >>  6) & 0x1f)
#define DIS_RE      ((Instr >>  1) & 0x1f)
#define DIS_MB      DIS_RC
#define DIS_ME      DIS_RE
#define DIS_OE      (Instr & 0x400)
#define DIS_SIMM    ((s16)Instr)
#define DIS_UIMM    (Instr & 0xffff)
#define DIS_CRM     ((Instr >> 12) & 0xff)
#define AA          (Instr & 2)
#define LK          (Instr & 1)
#define AALK        (Instr & 3)
#define Rc          LK

// GPRs. sp, sd1 and sd2 are named corresponding to PPC EABI.
static const char *regname[] = {
#ifdef UPPERCASE
 "R0" , "R1" , "R2", "R3" , "R4" , "R5" , "R6" , "R7" , 
 "R8" , "R9" , "R10", "R11", "R12", "R13", "R14", "R15", 
 "R16", "R17", "R18", "R19", "R20", "R21", "R22", "R23", 
 "R24", "R25", "R26", "R27", "R28", "R29", "R30", "R31"
#else
 "r0" , "r1" , "r2", "r3" , "r4" , "r5" , "r6" , "r7" , 
 "r8" , "r9" , "r10", "r11", "r12", "r13", "r14", "r15", 
 "r16", "r17", "r18", "r19", "r20", "r21", "r22", "r23", 
 "r24", "r25", "r26", "r27", "r28", "r29", "r30", "r31"
#endif
};
#define REGD        (regname[DIS_RD])
#define REGS        (regname[DIS_RS])
#define REGA        (regname[DIS_RA])
#define REGB        (regname[DIS_RB])

// Hopper operand build helpers
static void DISASM_PPC_BUILD_IMM_OP(int64_t imm, bool hex)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_CONSTANT_TYPE | DISASM_OPERAND_RELATIVE;
    op->immediateValue = (imm);
    if (hex)
        op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
}

static void DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(int64_t imm)
{
    Address addr = o->disasm->instruction.addressValue;
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_CONSTANT_TYPE | DISASM_OPERAND_ABSOLUTE;
    op->immediateValue = addr;
    op->isBranchDestination = 1;
    op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
}

static void DISASM_PPC_BUILD_IMM_REL_BDEST_OP(int64_t imm)
{
    Address addr = o->disasm->instruction.addressValue;
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_CONSTANT_TYPE | DISASM_OPERAND_RELATIVE;
    op->immediateValue = addr;
    op->memory.displacement = (imm);
    op->isBranchDestination = 1;
    op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
}

static void DISASM_PPC_BUILD_CR_OP(int idx, bool write)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_REGISTER_TYPE;
    op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_PPC_CondReg);
    op->type |= DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    if (write) {
        op->accessMode = DISASM_ACCESS_WRITE;
        o->disasm->implicitlyWrittenRegisters[RegClass_PPC_CondReg] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    } else {
        op->accessMode = DISASM_ACCESS_READ;
        o->disasm->implicitlyReadRegisters[RegClass_PPC_CondReg] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    }
}

static void DISASM_PPC_BUILD_GPR_OP(int idx, bool write)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_REGISTER_TYPE;
    op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_GeneralPurposeRegister);
    op->type |= DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    if (write) {
        op->accessMode = DISASM_ACCESS_WRITE;
        o->disasm->implicitlyWrittenRegisters[RegClass_GeneralPurposeRegister] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
        if (o->lisArr) o->lisArr[idx] = ~0;
    } else {
        op->accessMode = DISASM_ACCESS_READ;
        o->disasm->implicitlyReadRegisters[RegClass_GeneralPurposeRegister] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    }
}

static void DISASM_PPC_BUILD_FPR_OP(int idx, bool write)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_REGISTER_TYPE;
    op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_FPRegister);
    op->type |= DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    if (write) {
        op->accessMode = DISASM_ACCESS_WRITE;
        o->disasm->implicitlyWrittenRegisters[RegClass_FPRegister] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    } else {
        op->accessMode = DISASM_ACCESS_READ;
        o->disasm->implicitlyReadRegisters[RegClass_FPRegister] |= (uint32_t)DISASM_BUILD_REGISTER_INDEX_MASK((idx));
    }
}

static const char *spr_name(int n)
{
    static char def[8];
    
    switch(n)
    {
            // General architecture special-purpose registers.
        case 1: return "XER";
        case 8: return "LR";
        case 9: return "CTR";
        case 18: return "DSISR";
        case 19: return "DAR";
        case 22: return "DEC";
        case 25: return "SDR1";
        case 26: return "SRR0";
        case 27: return "SRR1";
        case 272: return "SPRG0";
        case 273: return "SPRG1";
        case 274: return "SPRG2";
        case 275: return "SPRG3";
#ifdef  POWERPC_64
        case 280: return "ASR";
#endif
        case 284: return "TBL";
        case 285: return "TBU";
        case 287: return "PVR";
        case 528: return "IBAT0U";
        case 529: return "IBAT0L";
        case 530: return "IBAT1U";
        case 531: return "IBAT1L";
        case 532: return "IBAT2U";
        case 533: return "IBAT2L";
        case 534: return "IBAT3U";
        case 535: return "IBAT3L";
        case 536: return "DBAT0U";
        case 537: return "DBAT0L";
        case 538: return "DBAT1U";
        case 539: return "DBAT1L";
        case 540: return "DBAT2U";
        case 541: return "DBAT2L";
        case 542: return "DBAT3U";
        case 543: return "DBAT3L";
            
            // Optional registers.
#if !defined(GEKKO) && !defined(BROADWAY)
        case 282: return "EAR";
        case 1013: return "DABR";
        case 1022: return "FPECR";
        case 1023: return "PIR";
#endif
            
            // Gekko-specific SPRs
#ifdef GEKKO
        case 282: return "EAR";
        case 912: return "GQR0";
        case 913: return "GQR1";
        case 914: return "GQR2";
        case 915: return "GQR3";
        case 916: return "GQR4";
        case 917: return "GQR5";
        case 918: return "GQR6";
        case 919: return "GQR7";
        case 920: return "HID2";
        case 921: return "WPAR";
        case 922: return "DMAU";
        case 923: return "DMAL";
        case 936: return "UMMCR0";
        case 940: return "UMMCR1";
        case 937: return "UPMC1";
        case 938: return "UPMC2";
        case 939: return "USIA";
        case 941: return "UPMC3";
        case 942: return "UPMC4";
        case 943: return "USDA";
        case 952: return "MMCR0";
        case 953: return "PMC1";
        case 954: return "PMC2";
        case 955: return "SIA";
        case 956: return "MMCR1";
        case 957: return "PMC3";
        case 958: return "PMC4";
        case 959: return "SDA";
        case 1008: return "HID0";
        case 1009: return "HID1";
        case 1010: return "IABR";
        case 1013: return "DABR";
        case 1017: return "L2CR";
        case 1019: return "ICTC";
        case 1020: return "THRM1";
        case 1021: return "THRM2";
        case 1022: return "THRM3";
#endif
    }
    
    sprintf(def, "%u", n);
    return def;
}

static const char *tbr_name(int n)
{
    static char def[8];
    
    switch(n)
    {
            // General architecture time-base registers.
        case 268: return "TBL";
        case 269: return "TBU";
    }
    
    sprintf(def, "%u", n);
    return def;
}

static void DISASM_PPC_BUILD_SPR_OP(int idx, bool write)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_OTHER;
    op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_SPRegister);
    strcpy(op->userString, spr_name(idx));
    if (write) {
        op->accessMode = DISASM_ACCESS_WRITE;
    } else {
        op->accessMode = DISASM_ACCESS_READ;
    }
}

static void DISASM_PPC_BUILD_TBR_OP(int idx, bool write)
{
    DisasmOperand* op = &o->disasm->operand[o->opIdx++];
    op->type = DISASM_OPERAND_OTHER;
    op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_TBRegister);
    strcpy(op->userString, tbr_name(idx));
    if (write) {
        op->accessMode = DISASM_ACCESS_WRITE;
    } else {
        op->accessMode = DISASM_ACCESS_READ;
    }
}

#define MASK32(b, e) \
{ \
u32 mask = ((u32)0xffffffff >> (b)) ^ (((e) >= 31) ? 0 : ((u32)0xffffffff) >> ((e) + 1)); \
o->target = ((b) > (e)) ? (~mask) : (mask); \
}

#define MASK64(b, e) \
{ \
u64 mask = ((u64)0xffffffffffffffff >> (b)) ^ (((e) >= 63) ? 0 : ((u64)0xffffffffffffffff) >> ((e) + 1)); \
o->target = ((b) > (e)) ? (~mask) : (mask); \
}

static void clear_mnemonic()
{
    o->mnemonic[0] = '\0';
    o->disasm->instruction.mnemonic[0] = '\0';
}

static void copy_mnemonic(const char* n)
{
    strncpy(o->mnemonic, n, sizeof(o->mnemonic));
    strncpy(o->disasm->instruction.mnemonic, n, sizeof(o->disasm->instruction.mnemonic));
}

static void format_mnemonic(const char* f, ...)
{
    va_list ap;
    va_start(ap, f);
    vsprintf(o->mnemonic, f, ap);
    va_end(ap);
    va_start(ap, f);
    vsprintf(o->disasm->instruction.mnemonic, f, ap);
    va_end(ap);
}

// Illegal instruction.
static void ill(void)
{
#if 1
    clear_mnemonic();
    o->operands[0] = '\0';
#else
    copy_mnemonic(".word");
    sprintf(o->operands, HEX1 "%08X" HEX2, Instr);
#endif
    o->iclass = PPC_DISA_ILLEGAL;
}

// Smart SIMM formatting (if hex=1, then force HEX; if s=1, use sign)
static char * simm(int val, int hex, int s)
{
    static char out[16];
    if( ((val >= -256) && (val <= 256)) && !hex) sprintf(out, "%i", val);
    else
    {
        u16 hexval = (u16)val;
        if((hexval & 0x8000) && s) sprintf(out, "-" HEX1 "%04X" HEX2, ((~hexval) & 0xffff) + 1);
        else sprintf(out, HEX1 "%04X" HEX2, hexval);
    }
    return out;
}

// Simple instruction form + reserved bitmask.
static void put(const char * mnem, u32 mask, u32 chkval, int iclass)
{
    if( (Instr & mask) != chkval ) { ill(); return; }
    o->iclass |= iclass;
    copy_mnemonic(mnem);
}
static void put2(const char * mnem, u32 mask){
    put(mnem, mask, 0, PPC_DISA_OTHER);
}
static void put3(const char * mnem, u32 mask, u32 chkval){
    put(mnem, mask, chkval, PPC_DISA_OTHER);
}

// Simplified mnemonic trap conditions
static const char * t_cond[32] = {
 NULL, "lgt", "llt", NULL, "eq", "lge", "lle", NULL,
 "gt", NULL, NULL, NULL, "ge", NULL, NULL, NULL,
 "lt", NULL, NULL, NULL, "le", NULL, NULL, NULL,
 "ne", NULL, NULL, NULL, NULL, NULL, NULL, NULL,
};

// Trap instructions.
static void trap(int L, int imm)
{
    static char t_mode[2] = { 'w', 'd' };
    int rd = DIS_RD;    // TO
    int s = (rd & 0x18) ? 1 : 0;
#ifdef  SIMPLIFIED
    if(t_cond[rd] != NULL)
    {
        format_mnemonic("t%c%s%c", t_mode[L & 1], t_cond[rd], imm ? 'i' : 0);
        if(imm)
        {
            sprintf(o->operands, "%s" COMMA "%s", REGA, simm(DIS_SIMM, 0, s));
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, false);
            DISASM_PPC_BUILD_IMM_OP(DIS_SIMM, false);
        }
        else
        {
            sprintf(o->operands, "%s" COMMA "%s", REGA, REGB);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, false);
            DISASM_PPC_BUILD_GPR_OP(DIS_RB, false);
        }
        o->iclass |= PPC_DISA_SIMPLIFIED;
    }
    else
#endif
    {
        format_mnemonic("t%c%c", t_mode[L & 1], imm ? 'i' : 0);
        if(imm)
        {
            sprintf(o->operands, "%i" COMMA "%s" COMMA "%s", rd, REGA, simm(DIS_SIMM, 0, s));
            DISASM_PPC_BUILD_GPR_OP(rd, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, false);
            DISASM_PPC_BUILD_IMM_OP(DIS_SIMM, false);
        }
        else
        {
            sprintf(o->operands, "%i" COMMA "%s" COMMA "%s", rd, REGA, REGB);
            DISASM_PPC_BUILD_GPR_OP(rd, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, false);
            DISASM_PPC_BUILD_GPR_OP(DIS_RB, false);
        }
    }
    if(L) o->iclass |= PPC_DISA_64;
    o->r[1] = DIS_RA; if(!imm) o->r[2] = DIS_RB;
    if(imm)
    {
        o->immed = Instr & 0xFFFF;
        if(o->immed & 0x8000) o->immed |= 0xFFFF0000;
    }
}

// DAB mask
#define DAB_D   4
#define DAB_A   2
#define DAB_B   1

// ASB mask
#define ASB_A   4
#define ASB_S   2
#define ASB_B   1

// cr%i 
#ifdef UPPERCASE
    static char crname[] = "CR";
#else
    static char crname[] = "cr";
#endif

// fr%i
#ifdef UPPERCASE
    static char fregname[] = "FR";
#else
    static char fregname[] = "fr";
#endif

// Integer instructions
// form: 'D'    rD, rA, (s)IMM
//       'S'    rA, rS, (s)IMM
//       'X'    rD, rA, rB
//       'Z'    rA, rS, rB
//       'F'    frD, rA, rB
// dab LSB bits : [D][A][B] (D should always present)
// 'hex' for logic opcodes, 's' for alu opcodes, 'crfD' and 'L' for cmp opcodes
// 'imm': 1 to show immediate operand
static void integer(const char *mnem, char form, int dab, int hex, int s, int crfD, int L, int imm)
{
    char * ptr = o->operands;
    int rd = DIS_RD, ra = DIS_RA, rb = DIS_RB;
    copy_mnemonic(mnem);
    if(crfD)
    {
        ptr += sprintf(ptr, "%s%i" COMMA, crname, rd >> 2); // CMP only
        DISASM_PPC_BUILD_CR_OP(rd >> 2, true);
    }
    if(L)
    {
        ptr += sprintf(ptr, "%i" COMMA, rd & 1);           // CMP only
        DISASM_PPC_BUILD_IMM_OP(rd & 1, hex);
    }
    if(form == 'D')
    {
        if(dab & DAB_D)
        {
            ptr += sprintf(ptr, "%s", REGD);
            DISASM_PPC_BUILD_GPR_OP(rd, true);
        }
        if(dab & DAB_A)
        {
            if(dab & DAB_D) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGA);
            DISASM_PPC_BUILD_GPR_OP(ra, false);
        }
        if(imm)
        {
            ptr += sprintf(ptr, COMMA "%s", simm(s ? DIS_SIMM : DIS_UIMM, hex, s));
            DISASM_PPC_BUILD_IMM_OP(s ? DIS_SIMM : DIS_UIMM, hex);
        }
    }
    else if(form == 'S')
    {
        s32 thisLis = ~0;
        if (o->lisArr && !strcmp(mnem, "ori"))
            thisLis = o->lisArr[DIS_RS];
            
        if(dab & ASB_A)
        {
            ptr += sprintf(ptr, "%s", REGA);
            DISASM_PPC_BUILD_GPR_OP(ra, true);
        }
        if(dab & ASB_S)
        {
            if(dab & ASB_A) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGS);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
        }
        if(imm)
        {
            ptr += sprintf(ptr, COMMA "%s", simm(s ? DIS_SIMM : DIS_UIMM, hex, s));
            DISASM_PPC_BUILD_IMM_OP(s ? DIS_SIMM : DIS_UIMM, hex);
        }
        
        if (thisLis != ~0)
        {
            DisasmOperand* op = &o->disasm->operand[o->opIdx-1];
            op->userData[0] |= DISASM_PPC_OPER_LIS_ADDI;
            op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
            op->userData[1] = thisLis | op->immediateValue;
            o->disasm->instruction.addressValue = op->userData[1];
            o->lisArr[DIS_RA] = (s32)op->userData[1];
        }
    }
    else if(form == 'X')    // DAB
    {
        if(dab & DAB_D)
        {
            ptr += sprintf(ptr, "%s", REGD);
            DISASM_PPC_BUILD_GPR_OP(rd, true);
        }
        if(dab & DAB_A)
        {
            if(dab & DAB_D) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGA);
            DISASM_PPC_BUILD_GPR_OP(ra, false);
        }
        if(dab & DAB_B)
        {
            if(dab & (DAB_D|DAB_A)) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGB);
            DISASM_PPC_BUILD_GPR_OP(rb, false);
        }
    }
    else if(form == 'F')    // FPU DAB
    {
        if(dab & DAB_D)
        {
            ptr += sprintf(ptr, "%s%i", fregname, rd);
            DISASM_PPC_BUILD_FPR_OP(rd, true);
        }
        if(dab & DAB_A)
        {
            if(dab & DAB_D) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGA);
            DISASM_PPC_BUILD_GPR_OP(ra, false);
        }
        if(dab & DAB_B)
        {
            if(dab & (DAB_D|DAB_A)) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGB);
            DISASM_PPC_BUILD_GPR_OP(rb, false);
        }
    }
    else if(form == 'Z')    // ASB
    {
        if(dab & ASB_A)
        {
            ptr += sprintf(ptr, "%s", REGA);
            DISASM_PPC_BUILD_GPR_OP(ra, true);
        }
        if(dab & ASB_S)
        {
            if(dab & ASB_A) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGS);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
        }
        if(dab & ASB_B)
        {
            if(dab & (ASB_A|ASB_S)) ptr += sprintf(ptr, "%s", COMMA);
            ptr += sprintf(ptr, "%s", REGB);
            DISASM_PPC_BUILD_GPR_OP(rb, false);
        }
    }
    else { ill(); return; }
    if(form == 'D' || form == 'X' || form == 'F') { o->r[0] = rd; o->r[1] = ra; }
    if(form == 'S' || form == 'Z') { o->r[0] = ra; o->r[1] = rd; }
    if(form == 'X' || form == 'Z' || form == 'F') o->r[2] = rb;
    if((form == 'D' || form == 'S') && imm)
    {
        o->immed = Instr & 0xFFFF;
        if(o->immed & 0x8000 && s) o->immed |= 0xFFFF0000;
    }
    o->iclass |= PPC_DISA_INTEGER;
}
static void integer3(const char *mnem, char form, int dab){
    integer(mnem, form, dab, 0, 1, 0, 0, 1);
}
static void integer4(const char *mnem, char form, int dab, int hex){
    integer(mnem, form, dab, hex, 1, 0, 0, 1);
}
static void integer5(const char *mnem, char form, int dab, int hex, int s){
    integer(mnem, form, dab, hex, s, 0, 0, 1);
}
static void integer6(const char *mnem, char form, int dab, int hex, int s, int crfD){
    integer(mnem, form, dab, hex, s, crfD, 0, 1);
}
static void integer7(const char *mnem, char form, int dab, int hex, int s, int crfD, int L){
    integer(mnem, form, dab, hex, s, crfD, L, 1);
}

// Compare instructions (wraps to integer call)
static void cmp(const char *l, const char *i)
{
    char mnem[sizeof(o->mnemonic)];
    int rd = DIS_RD;
    
    if(rd & 2) { ill(); return; }   // Reserved bit set
    if(rd & 1)
    {
#ifndef  POWERPC_64
        { ill(); return; }
#endif
        o->iclass |= PPC_DISA_64;
    }

#ifdef  SIMPLIFIED
    sprintf(mnem, "cmp%s%c%s", l, (rd & 1) ? 'd' : 'w', i);
    integer7(mnem, (*i == 'i') ? 'D' : 'X', DAB_A|DAB_B, 0, 1, (rd >> 2) ? 1 : 0, 0);
    o->iclass |= PPC_DISA_SIMPLIFIED;
#else
    sprintf(mnem, "cmp%s%s", l, i);
    integer(mnem, (*i == 'i') ? 'D' : 'X', DAB_A|DAB_B, 0, 1, 1, 1);
#endif
}

// Add immediate (wraps to integer call)
static void addi(const char *suffix)
{
    char mnem[sizeof(o->mnemonic)];

#ifdef  SIMPLIFIED
    if( (suffix[0] == '\0') && (DIS_RA == 0) )  // Load immediate
    {
        integer5("li", 'D', DAB_D, 0, 1);
        if (o->lisArr)
            o->lisArr[DIS_RD] = DIS_SIMM;
        o->iclass |= PPC_DISA_SIMPLIFIED;
        return;
    }
    if( (suffix[0] == 's') && (DIS_RA == 0) )   // Load address HI
    {
        integer5("lis", 'D', DAB_D, 1, 0);
        if (o->lisArr)
            o->lisArr[DIS_RD] = DIS_SIMM << 16;
        o->iclass |= PPC_DISA_SIMPLIFIED;
        return;
    }
    if(DIS_UIMM & 0x8000)
    {
        sprintf(mnem, "subi%s", suffix);

        // Fix immediate field.
        u16 value = (u16)(~(DIS_UIMM) + 1);
        Instr = (Instr & ~0xFFFF) | value;

        s32 thisLis = o->lisArr ? o->lisArr[DIS_RA] : ~0;
        integer5(mnem, 'D', DAB_D|DAB_A, 0, 1);
        o->iclass |= PPC_DISA_SIMPLIFIED;
        if (thisLis != ~0)
        {
            DisasmOperand* op = &o->disasm->operand[o->opIdx-1];
            op->userData[0] |= DISASM_PPC_OPER_LIS_ADDI;
            op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
            op->userData[1] = thisLis - op->immediateValue;
            o->disasm->instruction.addressValue = op->userData[1];
            o->lisArr[DIS_RD] = op->userData[1];
        }
    }
    else
    {
        sprintf(mnem, "addi%s", suffix);
        s32 thisLis = o->lisArr ? o->lisArr[DIS_RA] : ~0;
        integer5(mnem, 'D', DAB_D|DAB_A, 0, 0);
        if (thisLis != ~0)
        {
            DisasmOperand* op = &o->disasm->operand[o->opIdx-1];
            op->userData[0] |= DISASM_PPC_OPER_LIS_ADDI;
            op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
            op->userData[1] = thisLis + op->immediateValue;
            o->disasm->instruction.addressValue = op->userData[1];
            o->lisArr[DIS_RD] = op->userData[1];
        }
    }
#else
    sprintf(mnem, "addi%s", suffix);
    integer(mnem, 'D', DAB_D|DAB_A);
#endif
}

// Branch suffix: AA || LK.
static const char *b_opt[4] = { "", "l", "a", "la" };

// Branch condition code: 4 * BO[1] + (BI & 3)
static const char * b_cond[8] = {
 "ge", "le", "ne", "ns", "lt", "gt", "eq", "so"
};

// Branch condition Hopper flags
static const DisasmBranchType b_hcond[8] = {
    DISASM_BRANCH_JNL,
    DISASM_BRANCH_JNG,
    DISASM_BRANCH_JNE,
    DISASM_BRANCH_JNO,
    DISASM_BRANCH_JL,
    DISASM_BRANCH_JG,
    DISASM_BRANCH_JE,
    DISASM_BRANCH_JO
};

// Branch on CTR code: BO[0..3]
static const char * b_ctr[16] = {
 "dnzf", "dzf", NULL, NULL, "dnzt", "dzt", NULL, NULL,
 "dnz", "dz", NULL, NULL, NULL, NULL, NULL, NULL
};

// Place target address in operands. Helper for bcx/bx calls.
static char *place_target(char *ptr, int comma)
{
    char *old;
#ifdef  POWERPC_64
    u32 *t = (u32 *)&o->target;
#endif

    if(comma) ptr += sprintf(ptr, "%s", COMMA);
    old = ptr;
#ifdef  POWERPC_32
    ptr += sprintf(ptr, HEX1 "%08lX" HEX2, (u32)o->target);
#endif
#ifdef  POWERPC_64
    ptr = old;
    if(bigendian) ptr += sprintf(ptr, HEX1 "%08X_%08X" HEX2, t[0], t[1]);
    else ptr += sprintf(ptr, HEX1 "%08X_%08X" HEX2, t[1], t[0]);
#endif
    return ptr;
}

// Branch conditional.
// Disp:1 - branch with displacement..
// Disp:0 - branch by register (L:1 for LR, L:0 for CTR).
static void bcx(int Disp, int L)
{
    o->disasm->instruction.branchType = DISASM_BRANCH_JMP;

    u64 bd = 0;
    int bo = DIS_RD, bi = DIS_RA;
    const char *r = Disp ? "" : (L ? "lr" : "ctr");
    o->disasm->instruction.userData |=
        Disp ? 0 : (L ? DISASM_PPC_INST_BRANCH_TO_LINK_REGISTER :
                        DISASM_PPC_INST_BRANCH_TO_COUNT_REGISTER);
    if (!Disp && L)
        o->disasm->instruction.branchType = DISASM_BRANCH_RET;
    char *ptr = o->operands;

    if( DIS_RB && !Disp ) { ill(); return; }

    o->operands[0] = '\0';
    o->target = 0;
    o->iclass |= PPC_DISA_BRANCH;

    // Calculate displacement and target address
    if(Disp)
    {
        bd = DIS_UIMM & ~3;
        if(bd & 0x8000) bd |= 0xffffffffffff0000;
        o->target = (AA ? 0 : DIS_PC) + bd;
    }
    else o->target = 0;
    o->disasm->instruction.addressValue = o->target;
    if (LK)
    {
        o->disasm->instruction.userData |= DISASM_PPC_INST_BRANCH_SET_LINK_REGISTER;
        o->disasm->instruction.branchType = DISASM_BRANCH_CALL;
    }

    // Calculate branch prediction hint
    char y = (bo & 1) ^ ((((s64)bd < 0) && Disp) ? 1 : 0);
    y = y ? '+' : '-';

    if(bo & 4)              // No CTR decrement                         // BO[2]
    {
        if(bo & 16)         // Branch always                            // BO[0]
        {
#ifdef  SIMPLIFIED
            format_mnemonic("b%s%s", r, b_opt[Disp ? AALK : LK]);
            if(Disp)
            {
                ptr = place_target(ptr, 0);
                if (AA)
                    DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(bd);
                else
                    DISASM_PPC_BUILD_IMM_REL_BDEST_OP(bd);
            }
            o->iclass |= PPC_DISA_SIMPLIFIED;
            return;
#endif  // SIMPLIFIED
        }
        else                // Branch conditional
        {
            if(bo & 2) { ill(); return; }                               // BO[3]
#ifdef  SIMPLIFIED
            const char *cond = b_cond[((bo & 8) >> 1) | (bi & 3)];
            if(cond != NULL)                                            // BO[1]
            {
                format_mnemonic("b%s%s%s%c", cond, r, b_opt[Disp ? AALK : LK], y);
                o->disasm->instruction.branchType = b_hcond[((bo & 8) >> 1) | (bi & 3)];
                if(bi >= 4)
                {
                    ptr += sprintf(ptr, "%s%i", crname, bi >> 2);
                    DISASM_PPC_BUILD_CR_OP(bi >> 2, true);
                }
                if(Disp)
                {
                    ptr = place_target(ptr, bi >= 4);
                    if (AA)
                        DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(bd);
                    else
                        DISASM_PPC_BUILD_IMM_REL_BDEST_OP(bd);
                }
                o->iclass |= PPC_DISA_SIMPLIFIED;
                return;
            }
#endif  // SIMPLIFIED
        }
    }
    else                    // Decrement CTR
    {
        if(!L && !Disp) { ill(); return; }
        if(bo & 8) { ill(); return; }                               // BO[1]
#ifdef  SIMPLIFIED
        if(b_ctr[bo >> 1])
        {
            format_mnemonic("b%s%s%s%c", b_ctr[bo >> 1], r, b_opt[Disp ? AALK : LK], y);
            if(!(bo & 16))
            {
                ptr += sprintf(ptr, "%i", bi);
                DISASM_PPC_BUILD_IMM_OP(bi, false);
            }
            if(Disp)
            {
                ptr = place_target(ptr, !(bo & 16));
                if (AA)
                    DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(bd);
                else
                    DISASM_PPC_BUILD_IMM_REL_BDEST_OP(bd);
            }
            o->iclass |= PPC_DISA_SIMPLIFIED;
            return;
        }
#endif  // SIMPLIFIED
    }

    // Not simplified standard form
    format_mnemonic("bc%s%s", r, b_opt[Disp ? AALK : LK]);
    ptr += sprintf(ptr, "%i" COMMA "%i", bo, bi);
    DISASM_PPC_BUILD_IMM_OP(bo, false);
    DISASM_PPC_BUILD_IMM_OP(bi, false);
    if(Disp)
    {
        ptr = place_target(ptr, 1);
        if (AA)
            DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(bd);
        else
            DISASM_PPC_BUILD_IMM_REL_BDEST_OP(bd);
    }
}

// Branch unconditional
static void bx(void)
{
    // Calculate displacement and target address
    u64 bd = Instr & 0x03fffffc;
    if(bd & 0x02000000) bd |= 0xfffffffffc000000;
    o->target = (AA ? 0 : DIS_PC) + bd;
    o->disasm->instruction.addressValue = o->target;
    o->disasm->instruction.branchType = DISASM_BRANCH_JMP;
    if (LK)
    {
        o->disasm->instruction.userData |= DISASM_PPC_INST_BRANCH_SET_LINK_REGISTER;
        o->disasm->instruction.branchType = DISASM_BRANCH_CALL;
    }

    o->iclass |= PPC_DISA_BRANCH;
    format_mnemonic("b%s", b_opt[AALK]);
    place_target(o->operands, 0);
    if (AA)
        DISASM_PPC_BUILD_IMM_ABS_BDEST_OP(bd);
    else
        DISASM_PPC_BUILD_IMM_REL_BDEST_OP(bd);
}

// Move CR field
static void mcrf(void)
{
    if(Instr & 0x63f801) { ill(); return; }
    copy_mnemonic("mcrf");
    sprintf(o->operands, "%s%lu" COMMA "%s%lu", crname, DIS_RD >> 2, crname, DIS_RA >> 2);
    DISASM_PPC_BUILD_CR_OP(DIS_RD >> 2, true);
    DISASM_PPC_BUILD_CR_OP(DIS_RA >> 2, false);
}

// CR logic operations
static void crop(const char *name, const char *simp, int ddd, int daa)
{
    if(Instr & 1) { ill(); return; }

    int crfD = DIS_RD, crfA = DIS_RA, crfB = DIS_RB;

#ifdef  SIMPLIFIED
    if( crfA == crfB )
    {
        if( (crfD == crfA) && ddd )
        {
            format_mnemonic("cr%s", simp);
            sprintf(o->operands, "%i", crfD);
            DISASM_PPC_BUILD_CR_OP(crfD, true);
            o->r[0] = crfD;
            o->iclass |= PPC_DISA_SIMPLIFIED;
            return;
        }
        if( daa )
        {
            format_mnemonic("cr%s", simp);
            sprintf(o->operands, "%i" COMMA "%i", crfD, crfA);
            DISASM_PPC_BUILD_CR_OP(crfD, true);
            DISASM_PPC_BUILD_CR_OP(crfA, false);
            o->r[0] = crfD; o->r[1] = crfA;
            o->iclass |= PPC_DISA_SIMPLIFIED;
            return;
        }
    }
#endif
    format_mnemonic("cr%s", name);
    sprintf(o->operands, "%i" COMMA "%i" COMMA "%i", crfD, crfA, crfB);
    DISASM_PPC_BUILD_CR_OP(crfD, true);
    DISASM_PPC_BUILD_CR_OP(crfA, false);
    DISASM_PPC_BUILD_CR_OP(crfB, false);
    o->r[0] = crfD; o->r[1] = crfA; o->r[2] = crfB;
}
static void crop1(const char *name){
    crop(name,"",0,0);
}
static void crop2(const char *name, const char *simp){
    crop(name,simp,0,0);
}
static void crop3(const char *name, const char *simp, int ddd){
    crop(name,simp,ddd,0);
}

#define DISASM_PPC_ADD_RLWINM_HELPER \
if (!rb) \
{ \
    DisasmOperand* op = &o->disasm->operand[o->opIdx-1]; \
    op->userData[0] |= DISASM_PPC_OPER_RLWIMI; \
    op->userData[1] = DIS_RB; \
    op->userData[2] = mb; \
    op->userData[3] = me; \
}

// Rotate left word.
static void rlw(const char *name, int rb, int ins)
{
    int mb = DIS_MB, me = DIS_ME;
    char * ptr = o->operands;
#ifdef SIMPLIFIED
    if (!rb && !ins)
    {
        // rlwinm
        if (DIS_RB == 0)
        {
            if (me == 31)
            {
                // clrlwi
                format_mnemonic("clrlwi%c", Rc ? '.' : '\0');
                ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%d", REGA, REGS, mb);
                DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
                DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
                DISASM_PPC_BUILD_IMM_OP(mb, false);
                DISASM_PPC_ADD_RLWINM_HELPER
                
                o->r[0] = DIS_RA;
                o->r[1] = DIS_RS;
                o->r[2] = mb;
                o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
                return;
            }
            else if (mb == 0)
            {
                // clrrwi
                format_mnemonic("clrrwi%c", Rc ? '.' : '\0');
                ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%d", REGA, REGS, 31 - me);
                DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
                DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
                DISASM_PPC_BUILD_IMM_OP(31 - me, false);
                DISASM_PPC_ADD_RLWINM_HELPER
                
                o->r[0] = DIS_RA;
                o->r[1] = DIS_RS;
                o->r[2] = 31 - me;
                o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
                return;
            }
        }
        
        if (mb == 0 && me == 31)
        {
            if (me + DIS_RB > 31)
            {
                // rotrwi
                format_mnemonic("rotrwi%c", Rc ? '.' : '\0');
                ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%lu", REGA, REGS, 32 - DIS_RB);
                DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
                DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
                DISASM_PPC_BUILD_IMM_OP(32 - DIS_RB, false);
                DISASM_PPC_ADD_RLWINM_HELPER
                
                o->r[0] = DIS_RA;
                o->r[1] = DIS_RS;
                o->r[2] = 32 - DIS_RB;
                o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            }
            else
            {
                // rotlwi
                format_mnemonic("rotlwi%c", Rc ? '.' : '\0');
                ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%lu", REGA, REGS, DIS_RB);
                DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
                DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
                DISASM_PPC_BUILD_IMM_OP(DIS_RB, false);
                DISASM_PPC_ADD_RLWINM_HELPER
                
                o->r[0] = DIS_RA;
                o->r[1] = DIS_RS;
                o->r[2] = DIS_RB;
                o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            }
            return;
        }
        
        if (mb == 0 && DIS_RB == 31 - me)
        {
            // slwi
            format_mnemonic("slwi%c", Rc ? '.' : '\0');
            ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%lu", REGA, REGS, DIS_RB);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
            DISASM_PPC_BUILD_IMM_OP(DIS_RB, false);
            DISASM_PPC_ADD_RLWINM_HELPER
            
            o->r[0] = DIS_RA;
            o->r[1] = DIS_RS;
            o->r[2] = DIS_RB;
            o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            return;
        }
        
        if (me == 31 && 32 - DIS_RB == mb)
        {
            // srwi
            format_mnemonic("srwi%c", Rc ? '.' : '\0');
            ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%d", REGA, REGS, mb);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
            DISASM_PPC_BUILD_IMM_OP(mb, false);
            DISASM_PPC_ADD_RLWINM_HELPER
            
            o->r[0] = DIS_RA;
            o->r[1] = DIS_RS;
            o->r[2] = mb;
            o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            return;
        }
        
        if (mb == 0 && me != 31)
        {
            // extlwi
            format_mnemonic("extlwi%c", Rc ? '.' : '\0');
            int n = me + 1;
            ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%d" COMMA "%lu", REGA, REGS, n, DIS_RB);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
            DISASM_PPC_BUILD_IMM_OP(n, false);
            DISASM_PPC_BUILD_IMM_OP(DIS_RB, false);
            DISASM_PPC_ADD_RLWINM_HELPER
            
            o->r[0] = DIS_RA;
            o->r[1] = DIS_RS;
            o->r[2] = n;
            o->r[3] = DIS_RB;
            o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            return;
        }
        
        if (mb != 0 && me == 31)
        {
            // extrwi
            format_mnemonic("extrwi%c", Rc ? '.' : '\0');
            int n = 32 - mb;
            int b = DIS_RB - n;
            ptr += sprintf(ptr, "%s" COMMA "%s" COMMA "%d" COMMA "%d", REGA, REGS, n, b);
            DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
            DISASM_PPC_BUILD_IMM_OP(n, false);
            DISASM_PPC_BUILD_IMM_OP(b, false);
            DISASM_PPC_ADD_RLWINM_HELPER
            
            o->r[0] = DIS_RA;
            o->r[1] = DIS_RS;
            o->r[2] = n;
            o->r[3] = b;
            o->iclass |= PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED;
            return;
        }
    }

#endif

    format_mnemonic("rlw%s%c", name, Rc ? '.' : '\0');
    ptr += sprintf(ptr, "%s" COMMA "%s" COMMA, REGA, REGS);
    DISASM_PPC_BUILD_GPR_OP(DIS_RA, true);
    DISASM_PPC_BUILD_GPR_OP(DIS_RS, false);
    if(rb)
    {
        ptr += sprintf(ptr, "%s" COMMA, REGB);
        DISASM_PPC_BUILD_GPR_OP(DIS_RB, false);
    }
    else
    {
        ptr += sprintf(ptr, "%lu" COMMA, DIS_RB);     // sh
        DISASM_PPC_BUILD_IMM_OP(DIS_RB, false);
    }
    ptr += sprintf(ptr, "%i" COMMA "%i", mb, me);
    DISASM_PPC_BUILD_IMM_OP(mb, false);
    DISASM_PPC_BUILD_IMM_OP(me, false);
    DISASM_PPC_ADD_RLWINM_HELPER
    
    // Put mask in target.
    MASK32(mb, me);
#ifdef POWERPC_64
    MASK64(mb+32, me+32);
#endif

    o->r[0] = DIS_RA;
    o->r[1] = DIS_RS;
    if(rb) o->r[2] = DIS_RB;
    o->iclass |= PPC_DISA_INTEGER;
}
static void rlw2(const char *name, int rb){
    rlw(name,rb,0);
}

// RLD mask
#define RLDM_LEFT       0       // MASK(b, 63)
#define RLDM_RIGHT      1       // MASK(0, e)
#define RLDM_INS        2       // MASK(b, ~n)

// Rotate left double-word.
static void rld(const char *name, int rb, int mtype)
{
#ifdef POWERPC_64
    int m = DIS_MB, n = DIS_RB;
    if(Instr & 0x20) m += 32;   // b or e
    if(Instr & 0x02) n += 32;   // sh

    char * ptr = o->operands;
    format_mnemonic("rld%s%c", name, Rc ? '.' : '\0');
    ptr += sprintf(ptr, "%s" COMMA "%s" COMMA, REGA, REGS);
    if(rb) ptr += sprintf(ptr, "%s" COMMA, REGB);
    else   ptr += sprintf(ptr, "%i" COMMA, n);
    ptr += sprintf(ptr, "%i", m);

    // Put mask in target.
    switch(mtype)
    {
        case RLDM_LEFT: MASK64(m, 63); break;
        case RLDM_RIGHT: MASK64(0, m); break;
        case RLDM_INS: MASK64(m, ~n); break;
    }

    o->r[0] = DIS_RA;
    o->r[1] = DIS_RS;
    if(rb) o->r[2] = DIS_RB;
    o->iclass |= PPC_DISA_64 | PPC_DISA_INTEGER;
#endif
}

// Load/Store.
static void ldst(const char *name, int x/*indexed*/, int load, int L, int string, int fload)
{
    uint32_t size = 0;
    int typeOff = 1;
    if (name[0] == 's' && name[1] == 't')
        typeOff = 2;
    switch (name[typeOff])
    {
    case 'w':
    default:
        size = 4;
        break;
    case 'h':
        size = 2;
        break;
    case 'b':
        size = 1;
        break;
    case 'f':
        if (name[typeOff+1] == 'd')
            size = 8;
        else
            size = 4;
        break;
    }
    
    if(x)
    {
        s32 thisLis = o->lisArr ? o->lisArr[DIS_RA] : ~0;

        integer3(name, fload ? 'F' : 'X', DAB_D|DAB_A|DAB_B);
        
        DisasmOperand* op = &o->disasm->operand[o->opIdx-1];
        op->type = DISASM_OPERAND_MEMORY_TYPE;
        op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_GeneralPurposeRegister);
        op->type |= DISASM_BUILD_REGISTER_INDEX_MASK(DIS_RB);
        op->size = size;
        op->memory.baseRegistersMask = DISASM_BUILD_REGISTER_INDEX_MASK(DIS_RA);
        op->memory.indexRegistersMask = DISASM_BUILD_REGISTER_INDEX_MASK(DIS_RB);
        op->memory.scale = 1;
        
        if (!load)
        {
            o->disasm->operand[0].accessMode = DISASM_ACCESS_READ;
            o->disasm->implicitlyReadRegisters[RegClass_GeneralPurposeRegister] |= DISASM_BUILD_REGISTER_INDEX_MASK(DIS_RD);
            o->disasm->implicitlyWrittenRegisters[RegClass_GeneralPurposeRegister] &= ~DISASM_BUILD_REGISTER_INDEX_MASK(DIS_RD);
        }
        
        if (thisLis != ~0)
        {
            o->disasm->instruction.userData |= DISASM_PPC_INST_INDEXED_LOAD_STORE;
            op->userData[1] = thisLis;
        }
    }
    else
    {
        int rd = DIS_RD, ra = DIS_RA;
        s16 imm = DIS_SIMM;
        copy_mnemonic(name);
        s32 thisLis = o->lisArr ? o->lisArr[ra] : ~0;
        if(fload)
        {
            sprintf (o->operands, "%s%i" COMMA "%s" LPAREN "%s" RPAREN, fregname, rd, simm(imm, 0, 1), regname[ra]);
            DISASM_PPC_BUILD_FPR_OP(rd, load);
            DISASM_PPC_BUILD_IMM_OP(imm, false);
            DISASM_PPC_BUILD_GPR_OP(ra, false);
        }
        else
        {
            sprintf (o->operands, "%s" COMMA "%s" LPAREN "%s" RPAREN, regname[rd], simm(imm, 0, 1), regname[ra]);
            DISASM_PPC_BUILD_GPR_OP(rd, load);
            DISASM_PPC_BUILD_IMM_OP(imm, false);
            DISASM_PPC_BUILD_GPR_OP(ra, false);
        }
        o->r[0] = rd;
        o->r[1] = ra;
        o->immed = DIS_UIMM & 0x8000 ? DIS_UIMM | 0xFFFF0000 : DIS_UIMM;
        o->disasm->instruction.userData |= DISASM_PPC_INST_LOAD_STORE;
        
        DisasmOperand* op = &o->disasm->operand[o->opIdx-1];
        op->type = DISASM_OPERAND_MEMORY_TYPE;
        op->type |= DISASM_BUILD_REGISTER_CLS_MASK(RegClass_GeneralPurposeRegister);
        op->type |= DISASM_BUILD_REGISTER_INDEX_MASK(ra);
        op->size = size;
        op->memory.baseRegistersMask = DISASM_BUILD_REGISTER_INDEX_MASK(ra);
        op->memory.displacement = imm;
        
        if (thisLis != ~0)
        {
            DisasmOperand* op = &o->disasm->operand[o->opIdx-2];
            op->userData[0] |= DISASM_PPC_OPER_LIS_ADDI;
            op->userData[0] |= DISASM_PPC_OPER_IMM_HEX;
            op->userData[1] = thisLis + op->immediateValue;
            o->disasm->instruction.addressValue = op->userData[1];
        }
    }

    o->iclass = PPC_DISA_LDST;
    if(L) o->iclass |= PPC_DISA_64;
    if(string) o->iclass |= PPC_DISA_STRING;
    if(fload) o->iclass |= PPC_DISA_FPU;
}
static void ldst2(const char *name, int x){
    ldst(name,x,1,0,0,0);
}
static void ldst3(const char *name, int x/*indexed*/, int load){
    ldst(name,x,load,0,0,0);
}
static void ldst4(const char *name, int x/*indexed*/, int load, int L){
    ldst(name,x,load,L,0,0);
}
static void ldst5(const char *name, int x/*indexed*/, int load, int L, int string){
    ldst(name,x,load,L,string,0);
}

// Cache.
static void cache(const char *name, int flag)
{
    if (DIS_RD) { ill(); return; }
    else
    {
        integer3(name, 'X', DAB_A|DAB_B);
        o->r[0] = o->r[1];
        o->r[1] = o->r[2];
        o->r[2] = 0;
        o->iclass &= ~PPC_DISA_INTEGER;
        o->iclass |= flag;
    }
}
static void cache1(const char *name){
    cache(name,PPC_DISA_OTHER);
}

static void movesr(const char *name, int from, int L, int xform)
{
    int reg = DIS_RD, sreg = DIS_RA & 0xF, regb = DIS_RB;

    copy_mnemonic(name);
    if(xform)
    {
        if(Instr & 0x001F0001) { ill(); return; }
        sprintf(o->operands, "%s" COMMA "%s", regname[reg], regname[regb]);
        DISASM_PPC_BUILD_GPR_OP(reg, true);
        DISASM_PPC_BUILD_GPR_OP(regb, false);
        o->r[0] = reg;
        o->r[1] = regb;
    }
    else
    {
        if(Instr & 0x0010F801) { ill(); return; }
        if(from)
        {
            sprintf(o->operands, "%s" COMMA "%i", regname[reg], sreg);
            DISASM_PPC_BUILD_GPR_OP(reg, true);
            DISASM_PPC_BUILD_IMM_OP(sreg, false);
            o->r[0] = reg;
            o->r[1] = sreg;
        }
        else
        {
            sprintf(o->operands, "%i" COMMA "%s", sreg, regname[reg]);
            DISASM_PPC_BUILD_IMM_OP(sreg, false);
            DISASM_PPC_BUILD_GPR_OP(reg, false);
            o->r[0] = sreg;
            o->r[1] = reg;
        }
    }

    if(L) o->iclass |= PPC_DISA_OEA | PPC_DISA_OPTIONAL | PPC_DISA_BRIDGE | PPC_DISA_64;
    else o->iclass |= PPC_DISA_OEA | PPC_DISA_BRIDGE;
}

static void mtcrf(void)
{
    int rs = DIS_RS, crm = DIS_CRM;

#ifdef SIMPLIFIED
    if(crm == 0xFF)
    {
        copy_mnemonic("mtcr");
        sprintf(o->operands, "%s", regname[rs]);
        DISASM_PPC_BUILD_GPR_OP(rs, false);
    }
    else
#endif
    {
        copy_mnemonic("mtcrf");
        sprintf(o->operands, HEX1 "%02X" HEX2 COMMA "%s", crm, regname[rs]);
        DISASM_PPC_BUILD_IMM_OP(crm, true);
        DISASM_PPC_BUILD_GPR_OP(rs, false);
    }
    o->r[0] = rs;
}

static void mcrxr(void)
{
    if (Instr & 0x007FF800) { ill(); return; }
    copy_mnemonic("mcrxr");
    sprintf (o->operands, "%s%lu", crname, DIS_RD >> 2);
    DISASM_PPC_BUILD_CR_OP(DIS_RD >> 2, true);
    o->r[0] = DIS_RD >> 2;
}

static void movespr(int from)
{
    int spr = (DIS_RB << 5) | DIS_RA, f = 1;
    const char *fix;

    if( !((spr == 1) || (spr == 8) || (spr == 9)) ) o->iclass |= PPC_DISA_OEA;

    // Handle simplified mnemonic
    if (spr == 1) { fix = "xer"; o->iclass |= PPC_DISA_SIMPLIFIED; }
    else if (spr == 8) { fix = "lr"; o->iclass |= PPC_DISA_SIMPLIFIED; }
    else if (spr == 9) { fix = "ctr"; o->iclass |= PPC_DISA_SIMPLIFIED; }
    else { fix = "spr"; f = 0; }

    // Mnemonics and operands.
    format_mnemonic("m%c%s", from ? 'f' : 't', fix);
    if (f)
    {
        sprintf (o->operands, "%s", regname[DIS_RD]);
        DISASM_PPC_BUILD_GPR_OP(DIS_RD, from);
        if (!from && spr == 8)
        o->r[0] = DIS_RD;
    }
    else
    {
        if (from)
        {
            sprintf (o->operands, "%s" COMMA "%s", regname[DIS_RD], spr_name(spr));
            DISASM_PPC_BUILD_GPR_OP(DIS_RD, true);
            DISASM_PPC_BUILD_SPR_OP(spr, false);
            o->r[0] = DIS_RD;
            o->r[1] = spr;
        }
        else
        {
            sprintf (o->operands, "%s" COMMA "%s", spr_name(spr), regname[DIS_RD]);
            DISASM_PPC_BUILD_SPR_OP(spr, true);
            DISASM_PPC_BUILD_GPR_OP(DIS_RD, false);
            o->r[0] = spr;
            o->r[1] = DIS_RD;
        }
    }
}

static void movetbr(void)
{
    int tbr = (DIS_RB << 5) | DIS_RA, f = 1;
    const char *fix;

    // Handle simplified mnemonic
    if (tbr == 268) { fix = "tbl"; o->iclass |= PPC_DISA_SIMPLIFIED; }
    else if (tbr == 269) { fix = "tbu"; o->iclass |= PPC_DISA_SIMPLIFIED; }
    else { fix = "tb"; f = 0; }

    // Mnemonics and operands.
    format_mnemonic("mf%s", fix);
    if (f)
    {
        sprintf (o->operands, "%s", regname[DIS_RD]);
        DISASM_PPC_BUILD_GPR_OP(DIS_RD, true);
        o->r[0] = DIS_RD;
    }
    else
    {
        sprintf (o->operands, "%s" COMMA "%s", regname[DIS_RD], tbr_name(tbr));
        DISASM_PPC_BUILD_GPR_OP(DIS_RD, true);
        DISASM_PPC_BUILD_TBR_OP(tbr, false);
        o->r[0] = DIS_RD;
        o->r[1] = tbr;
    }
}

static void srawi(void)
{
    int rs = DIS_RS, ra = DIS_RA, sh = DIS_RB;
    format_mnemonic("srawi%c", Rc ? '.' : 0);
    sprintf (o->operands, "%s" COMMA "%s" COMMA "%i", regname[ra], regname[rs], sh);
    DISASM_PPC_BUILD_GPR_OP(ra, true);
    DISASM_PPC_BUILD_GPR_OP(rs, false);
    DISASM_PPC_BUILD_IMM_OP(sh, false);
    o->r[0] = ra;
    o->r[1] = rs;
    o->r[2] = sh;
    o->iclass = PPC_DISA_INTEGER;
}

static void sradi(void)
{
    int rs = DIS_RS, ra = DIS_RA, sh = (((Instr >> 1) & 1) << 5) | DIS_RB;
    format_mnemonic("sradi%c", Rc ? '.' : 0);
    sprintf (o->operands, "%s" COMMA "%s" COMMA "%i", regname[ra], regname[rs], sh);
    o->r[0] = ra;
    o->r[1] = rs;
    o->r[2] = sh;
    o->iclass = PPC_DISA_INTEGER | PPC_DISA_64;
}

static void lsswi(const char *name)
{
    int rd = DIS_RD, ra = DIS_RA, nb = DIS_RB;
    copy_mnemonic(name);
    sprintf (o->operands, "%s" COMMA "%s" COMMA "%i", regname[rd], regname[ra], nb);
    DISASM_PPC_BUILD_GPR_OP(rd, true);
    DISASM_PPC_BUILD_GPR_OP(ra, false);
    DISASM_PPC_BUILD_IMM_OP(nb, false);
    for (int i = 0; i < (nb + 3) / 4; ++i)
    {
        if (ra + i < 32)
            o->disasm->implicitlyReadRegisters[RegClass_GeneralPurposeRegister] |= DISASM_BUILD_REGISTER_INDEX_MASK(ra + i);
        if (rd + i < 32)
            o->disasm->implicitlyWrittenRegisters[RegClass_GeneralPurposeRegister] |= DISASM_BUILD_REGISTER_INDEX_MASK(rd + i);
    }
    o->r[0] = rd;
    o->r[1] = ra;
    o->r[2] = nb;
    o->iclass = PPC_DISA_LDST | PPC_DISA_STRING;
}

#define FPU_DAB     1
#define FPU_DB      2
#define FPU_DAC     3
#define FPU_DACB    4
#define FPU_D       5

static void fpu(const char *name, u32 mask, int type, int flag)
{
    int d = DIS_RD, a = DIS_RA, c = DIS_RC, b = DIS_RB;

    if(Instr & mask) { ill(); return; }

    copy_mnemonic(name);

    switch (type)
    {
        case FPU_DAB:
            sprintf (o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, b);
            DISASM_PPC_BUILD_FPR_OP(d, true);
            DISASM_PPC_BUILD_FPR_OP(a, false);
            DISASM_PPC_BUILD_FPR_OP(b, false);
            o->r[0] = d; o->r[1] = a; o->r[2] = b;
            break;
        case FPU_DB:
            sprintf (o->operands, "%s%i" COMMA "%s%i", fregname, d, fregname, b);
            DISASM_PPC_BUILD_FPR_OP(d, true);
            DISASM_PPC_BUILD_FPR_OP(b, false);
            o->r[0] = d; o->r[1] = b;
            break;
        case FPU_DAC:
            sprintf (o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, c);
            DISASM_PPC_BUILD_FPR_OP(d, true);
            DISASM_PPC_BUILD_FPR_OP(a, false);
            DISASM_PPC_BUILD_FPR_OP(c, false);
            o->r[0] = d; o->r[1] = a; o->r[2] = c;
            break;
        case FPU_DACB:
            sprintf (o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, c, fregname, b);
            DISASM_PPC_BUILD_FPR_OP(d, true);
            DISASM_PPC_BUILD_FPR_OP(a, false);
            DISASM_PPC_BUILD_FPR_OP(c, false);
            DISASM_PPC_BUILD_FPR_OP(b, false);
            o->r[0] = d; o->r[1] = a; o->r[2] = c; o->r[3] = b;
            break;
        case FPU_D:
            sprintf (o->operands, "%s%i", fregname, d);
            DISASM_PPC_BUILD_FPR_OP(d, true);
            o->r[0] = d;
            break;
    }
    
    o->iclass = PPC_DISA_FPU | flag;
}
static void fpu3(const char *name, u32 mask, int type){
    fpu(name,mask,type,PPC_DISA_OTHER);
}

static void fcmp(const char *name)
{
    int crfd = DIS_RD >> 2, ra = DIS_RA, rb = DIS_RB;

    if (Instr & 0x00600001) { ill(); return; }

    copy_mnemonic(name);
    sprintf (o->operands, "%i" COMMA "%s%i" COMMA "%s%i", crfd, fregname, ra, fregname, rb);
    DISASM_PPC_BUILD_CR_OP(crfd, true);
    DISASM_PPC_BUILD_FPR_OP(ra, false);
    DISASM_PPC_BUILD_FPR_OP(rb, false);
    o->r[0] = crfd; o->r[1] = ra; o->r[2] = rb;
    o->iclass = PPC_DISA_FPU;
}

static void mtfsf(void)
{
    int fm = (Instr >> 17) & 0xFF, rb = DIS_RB;

    if(Instr & 0x02010000) { ill(); return; }

    format_mnemonic("mtfsf%c", Rc ? '.' : 0);
    sprintf (o->operands, HEX1 "%02X" HEX2 COMMA "%s%i", fm, fregname, rb);
    DISASM_PPC_BUILD_IMM_OP(fm, false);
    DISASM_PPC_BUILD_FPR_OP(rb, false);
    o->r[0] = fm; o->r[1] = rb;
    o->iclass = PPC_DISA_FPU;
}

static void mtfsb(const char *name)
{
    int crbd = DIS_RD;

    if (Instr & 0x001FF800) { ill(); return; }

    copy_mnemonic(name);
    sprintf (o->operands, "%i", crbd);
    DISASM_PPC_BUILD_IMM_OP(crbd, false);
    o->r[0] = crbd;
    o->iclass = PPC_DISA_FPU;
}

static void mcrfs(void)
{
    int crfD = DIS_RD >> 2, crfS = DIS_RA >> 2;

    if (Instr & 0x0063F801) { ill(); return; }

    copy_mnemonic("mcrfs");
    sprintf (o->operands, "%s%i" COMMA "%s%i", crname, crfD, crname, crfS);
    DISASM_PPC_BUILD_CR_OP(crfD, true);
    DISASM_PPC_BUILD_CR_OP(crfS, false);
    o->r[0] = crfD; o->r[1] = crfS;
    o->iclass = PPC_DISA_FPU;
}

static void mtfsfi(void)
{
    int crfD = DIS_RD >> 2, imm = DIS_RB >> 1;

    if (Instr & 0x007F0800) { ill(); return; }

    format_mnemonic("mtfsfi%c", Rc ? '.' : 0);
    sprintf (o->operands, "%s%i" COMMA "%i", crname, crfD, imm);
    DISASM_PPC_BUILD_CR_OP(crfD, true);
    DISASM_PPC_BUILD_IMM_OP(imm, false);
    o->r[0] = crfD; o->r[1] = imm;
    o->iclass = PPC_DISA_FPU;
}

/*
 ***********************************************************************************
 * Architecture-specific extensions: 
 * Processor model: GEKKO
 ***********************************************************************************
*/

#ifdef  GEKKO

static void ps_cmpx(int n)
{
    static char *fix[] = { "u0", "o0", "u1", "o1" };
    if(Instr & 0x00600001) { ill(); return; }
    format_mnemonic("ps_cmp%s", fix[n]);
    o->r[0] = DIS_RD>>2; o->r[1] = DIS_RA; o->r[2] = DIS_RB;
    sprintf(o->operands, "%s%d" COMMA "%s%d" COMMA "%s%d", crname, o->r[0], fregname, o->r[1], fregname, o->r[2]);
    DISASM_PPC_BUILD_CR_OP(o->r[0], true);
    DISASM_PPC_BUILD_FPR_OP(o->r[1], false);
    DISASM_PPC_BUILD_FPR_OP(o->r[2], false);
    o->iclass = PPC_DISA_FPU | PPC_DISA_SPECIFIC; 
}

static char *ps_ldst_offs(unsigned long val)
{
    static char buf[8];

    if(val == 0)
    {
        return "0";
    }
    else
    {
        if(val <= 128)
        {
            sprintf(buf, "%i", val);
            return buf;
        }

        if(val & 0x800) sprintf(buf, "-" HEX1 "%03X" HEX2, ((~val) & 0xfff) + 1);
        else sprintf(buf, HEX1 "%03X" HEX2, val);

        return buf;
    }
}

static void ps_ldst(char *fix)
{
    int s = DIS_RS, a = DIS_RA, d = (Instr & 0xfff);
    format_mnemonic("psq_%s", fix);
    sprintf( o->operands, "%s%i" COMMA "%s" LPAREN "%s" RPAREN COMMA "%i" COMMA "%i",
             fregname, s, ps_ldst_offs(d), regname[a], (Instr >> 15) & 1, (Instr >> 12) & 7 );
    o->r[0] = s; o->r[1] = a; o->r[2] = DIS_RB >> 1;
    o->immed = d & 0x800 ? d | 0xFFFFF000 : d;
    o->iclass = PPC_DISA_FPU | PPC_DISA_LDST | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(s, true);
    DISASM_PPC_BUILD_IMM_OP((s32)(d & 0x800 ? d | 0xFFFFF000 : d), true);
    DISASM_PPC_BUILD_GPR_OP(a, false);
    DISASM_PPC_BUILD_IMM_OP((Instr >> 15) & 1, false);
    DISASM_PPC_BUILD_IMM_OP((Instr >> 12) & 7, false);
    o->disasm->instruction.userData |= DISASM_PPC_INST_LOAD_STORE;
}

static void ps_ldstx(char *fix)
{
    int d = DIS_RD, a = DIS_RA, b = DIS_RB;
    if(Instr & 1) { ill(); return; }
    format_mnemonic("psq_%s", fix);
    sprintf(o->operands, "%s%i" COMMA "%s" COMMA "%s" COMMA "%i" COMMA "%i", fregname, d, regname[a], regname[b], (Instr >> 10) & 1, (Instr >> 7) & 7);
    o->r[0] = d; o->r[1] = a; o->r[2] = b; o->r[3] = DIS_RC >> 1;
    o->iclass = PPC_DISA_FPU | PPC_DISA_LDST | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(d, true);
    DISASM_PPC_BUILD_GPR_OP(a, false);
    DISASM_PPC_BUILD_GPR_OP(b, false);
    DISASM_PPC_BUILD_IMM_OP((Instr >> 10) & 1, false);
    DISASM_PPC_BUILD_IMM_OP((Instr >> 7) & 7, false);
}

static void ps_dacb(char *fix)
{
    int a = DIS_RA, b = DIS_RB, c = DIS_RC, d = DIS_RD;
    format_mnemonic("ps_%s%c", fix, Rc ? '.' : 0);
    sprintf(o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, c, fregname, b);
    o->r[0] = d; o->r[1] = a; o->r[2] = c; o->r[3] = b; 
    o->iclass = PPC_DISA_FPU | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(d, true);
    DISASM_PPC_BUILD_FPR_OP(a, false);
    DISASM_PPC_BUILD_FPR_OP(c, false);
    DISASM_PPC_BUILD_FPR_OP(b, false);
}

static void ps_dac(char *fix)
{
    int a = DIS_RA, c = DIS_RC, d = DIS_RD;
    if(Instr & 0x0000F800) { ill(); return; }
    format_mnemonic("ps_%s%c", fix, Rc ? '.' : 0);
    sprintf(o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, c);
    o->r[0] = d; o->r[1] = a; o->r[2] = c;
    o->iclass = PPC_DISA_FPU | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(d, true);
    DISASM_PPC_BUILD_FPR_OP(a, false);
    DISASM_PPC_BUILD_FPR_OP(c, false);
}

static void ps_dab(char *fix, int unmask)
{
    int d = DIS_RD, a = DIS_RA, b = DIS_RB;
    if(Instr & 0x000007C0 && !unmask) { ill(); return; }
    format_mnemonic("ps_%s%c", fix, Rc ? '.' : 0);
    sprintf(o->operands, "%s%i" COMMA "%s%i" COMMA "%s%i", fregname, d, fregname, a, fregname, b);
    o->r[0] = d; o->r[1] = a; o->r[2] = b;
    o->iclass = PPC_DISA_FPU | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(d, true);
    DISASM_PPC_BUILD_FPR_OP(a, false);
    DISASM_PPC_BUILD_FPR_OP(b, false);
}

static void ps_db(char *fix, int aonly)
{
    int d = DIS_RD, b = DIS_RB;
    if(aonly) { if(Instr & 0x001F0000) { ill(); return; } }
    else  { if(Instr & 0x001F07C0) { ill(); return; } }
    format_mnemonic("ps_%s%c", fix, Rc ? '.' : 0);
    sprintf(o->operands, "%s%i" COMMA "%s%i", fregname, d, fregname, b);
    o->r[0] = d; o->r[1] = b;
    o->iclass = PPC_DISA_FPU | PPC_DISA_SPECIFIC;
    
    DISASM_PPC_BUILD_FPR_OP(d, true);
    DISASM_PPC_BUILD_FPR_OP(b, false);
}

#endif  /* END OF GEKKO */

// ---------------------------------------------------------------------------

void PPCDisasm(PPCD_CB *discb)
{
    // Save parameters in local variables for static calls
    o = discb;
    if(o == NULL) return;

    // Detect endianness order.
    if(bigendian == -1)
    {
        u8 test_value[2] = { 0xAA, 0xBB };
        u16 *value = (u16 *)test_value;
        if(*value == 0xAABB) bigendian = 1;
        else bigendian = 0;
    }

    // Reset output parameters
    o->iclass = PPC_DISA_OTHER;
    o->r[0] = o->r[1] = o->r[2] = o->r[3] = 0;
    o->immed = 0;
    o->target = 0;
    o->mnemonic[0] = o->operands[0] = '\0';
    o->opIdx = 0;

    // Lets go!

    /*
     * Main table
    */

    switch(Instr >> 26 /* Main opcode, base 8 */) {
#ifdef POWERPC_64
        case 002: trap(1, 1); break;                                        // tdi
#endif
        case 003: trap(0, 1); break;                                        // twi
        case 007: integer3("mulli", 'D', DAB_D|DAB_A); break;                // mulli
        case 010: integer3("subfic", 'D', DAB_D|DAB_A); break;               // subfic
        case 012: cmp("l", "i"); break;                                     // cmpli
        case 013: cmp("", "i"); break;                                      // cmpi
        case 014: addi("c"); break;                                         // addic
        case 015: addi("c."); break;                                        // addic.
        case 016: addi(""); break;                                          // addi
        case 017: addi("s"); break;                                         // addis
        case 020: bcx(1, 0); break;                                         // bcx
        case 021: put3("sc", 0x03ffffff, 2); break;                          // sc
        case 022: bx(); break;                                              // bx
        case 024: rlw("imi", 0, 1); break;                                  // rlwimix
        case 025: rlw2("inm", 0); break;                                     // rlwinmx
        case 027: rlw2("nm", 1); break;                                      // rlwnmx
        case 030:                                                           // ori
#ifdef SIMPLIFIED
                  if(Instr == 0x60000000) put("nop", 0, 0, PPC_DISA_INTEGER | PPC_DISA_SIMPLIFIED);
                  else
#endif
                  integer5("ori", 'S', ASB_A|ASB_S, 1, 0); break;
        case 031: integer5("oris", 'S', ASB_A|ASB_S, 1, 0); break;           // oris
        case 032: integer5("xori", 'S', ASB_A|ASB_S, 1, 0); break;           // xori
        case 033: integer5("xoris", 'S', ASB_A|ASB_S, 1, 0); break;          // xoris
        case 034: integer5("andi.", 'S', ASB_A|ASB_S, 1, 0); break;          // andi.
        case 035: integer5("andis.", 'S', ASB_A|ASB_S, 1, 0); break;         // andis.
        case 040: ldst3("lwz", 0, 1); break;                                 // lwz
        case 041: ldst3("lwzu", 0, 1); break;                                // lwzu
        case 042: ldst3("lbz", 0, 1); break;                                 // lbz
        case 043: ldst3("lbzu", 0, 1); break;                                // lbzu
        case 044: ldst3("stw", 0, 0); break;                                 // stw
        case 045: ldst3("stwu", 0, 0); break;                                // stwu
        case 046: ldst3("stb", 0, 0); break;                                 // stb
        case 047: ldst3("stbu", 0, 0); break;                                // stbu
        case 050: ldst3("lhz", 0, 1); break;                                 // lhz
        case 051: ldst3("lhzu", 0, 1); break;                                // lhzu
        case 052: ldst3("lha", 0, 1); break;                                 // lha
        case 053: ldst3("lhau", 0, 1); break;                                // lhau
        case 054: ldst3("sth", 0, 0); break;                                 // sth
        case 055: ldst3("sthu", 0, 0); break;                                // sthu
        case 056: ldst5("lmw", 0, 1, 0, 1); break;                           // lmw
        case 057: ldst5("stmw", 0, 0, 0, 1); break;                          // stmw
        case 060: ldst("lfs", 0, 1, 0, 0, 1); break;                        // lfs
        case 061: ldst("lfsu", 0, 1, 0, 0, 1); break;                       // lfsu
        case 062: ldst("lfd", 0, 1, 0, 0, 1); break;                        // lfd
        case 063: ldst("lfdu", 0, 1, 0, 0, 1); break;                       // lfdu
        case 064: ldst("stfs", 0, 0, 0, 0, 1); break;                       // stfs
        case 065: ldst("stfsu", 0, 0, 0, 0, 1); break;                      // stfsu
        case 066: ldst("stfd", 0, 0, 0, 0, 1); break;                       // stfd
        case 067: ldst("stfdu", 0, 0, 0, 0, 1); break;                      // stfdu

    /*
     * Extention 1.
    */

        case 023:
    switch((Instr >> 1) & 0x3ff /* Extended opcode 023, base 8 */) {
        case 00020: bcx(0, 1); break;                                       // bclrx
        case 01020: bcx(0, 0); break;                                       // bcctrx
        case 00000: mcrf(); break;                                          // mcrf
        case 00401: crop1("and"); break;                                     // crand
        case 00201: crop1("andc"); break;                                    // crandc
        case 00441: crop3("eqv", "set", 1); break;                           // creqv
        case 00341: crop1("nand"); break;                                    // crnand
        case 00041: crop("nor", "not", 0, 1); break;                        // crnor
        case 00701: crop("or", "move", 0, 1); break;                        // cror
        case 00641: crop1("orc"); break;                                     // crorc
        case 00301: crop3("xor", "clr", 1); break;                           // crxor
        case 00226: put2("isync", 0x3fff801); break;                         // isync
#ifdef  POWERPC_32
        case 00062: put("rfi", 0x3fff801, 0, PPC_DISA_OEA | PPC_DISA_BRIDGE ); break; // rfi
#endif
#ifdef  POWERPC_64
        case 00022: put("rfid", 0x3fff801, 0, PPC_DISA_OEA | PPC_DISA_64 ); break; // rfid
#endif
        default: ill(); break;
    } break;

#ifdef  POWERPC_64
        case 036:
    switch((Instr >> 1) & 0xf /* Rotate left double */) {
        case 0x0: rld("icl", 0, RLDM_LEFT); break;                          // rldiclx
        case 0x1: rld("icl", 0, RLDM_LEFT); break;
        case 0x2: rld("icr", 0, RLDM_RIGHT); break;                         // rldicrx
        case 0x3: rld("icr", 0, RLDM_RIGHT); break;
        case 0x4: rld("ic",  0, RLDM_INS); break;                           // rldicx
        case 0x5: rld("ic",  0, RLDM_INS); break;
        case 0x6: rld("imi", 0, RLDM_INS); break;                           // rldimix
        case 0x7: rld("imi", 0, RLDM_INS); break;
        case 0x8: rld("cl",  1, RLDM_LEFT); break;                          // rldclx
        case 0x9: rld("cr",  1, RLDM_RIGHT); break;                         // rldcrx
        default: ill(); break;
    } break;
#endif

    /*
     * Extention 2.
    */

        #define OE 02000
        case 037:
    switch(Instr & 0x7ff /* Extended opcode 037, base 8 */) {
        case 00000: cmp("", ""); break;                                     // cmp
        case 00010:                                                         // tw
#ifdef SIMPLIFIED
                    if(Instr == 0x7FE00008) put("trap", 0, 0, PPC_DISA_SIMPLIFIED);
                    else
#endif
                    trap(0, 0); break;
        case 00020: integer3("subfc", 'X', DAB_D|DAB_A|DAB_B); break;        // subfcx
        case 00020|OE: integer3("subfco", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00021: integer3("subfc.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00021|OE: integer3("subfco.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00024: integer3("addc", 'X', DAB_D|DAB_A|DAB_B); break;         // addcx
        case 00024|OE: integer3("addco", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00025: integer3("addc.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00025|OE: integer3("addco.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00026: integer3("mulhwu", 'X', DAB_D|DAB_A|DAB_B); break;       // mulhwu
        case 00027: integer3("mulhwu.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00046: if(DIS_RA | DIS_RB) ill();                              // mfcr
                    else { integer("mfcr", 'D', DAB_D, 0,0,0,0,0); o->iclass = PPC_DISA_OTHER; } break;
        case 00050: ldst2("lwarx", 1); break;                                // lwarx
        case 00056: ldst2("lwzx", 1); break;                                 // lwzx
        case 00060: integer3("slw", 'Z', ASB_A|ASB_S|ASB_B); break;          // slwx
        case 00061: integer3("slw.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 00064: if(DIS_RB) ill();                                       // cntlzwx
                    else integer("cntlzw", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 00065: if(DIS_RB) ill();
                    else integer("cntlzw.", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 00070: integer3("and", 'Z', ASB_A|ASB_S|ASB_B); break;          // andx
        case 00071: integer3("and.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 00100: cmp("l", ""); break;                                    // cmpl
        case 00120: integer3("subf", 'X', DAB_D|DAB_A|DAB_B); break;         // subfx
        case 00120|OE: integer3("subfo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00121: integer3("subf.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00121|OE: integer3("subfo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00154: cache1("dcbst"); break;                                  // dcbst
        case 00156: ldst2("lwzux", 1); break;                                // lwzux
        case 00170: integer3("andc", 'Z', ASB_A|ASB_S|ASB_B); break;         // andcx
        case 00171: integer3("andc.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 00226: integer3("mulhw", 'X', DAB_D|DAB_A|DAB_B); break;        // mulhw
        case 00227: integer3("mulhw.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00246: if(DIS_RA || DIS_RB) ill();                             // mfmsr
                    else { integer3("mfmsr", 'X', DAB_D); o->iclass = PPC_DISA_OEA; } break;
        case 00254: cache1("dcbf"); break;                                   // dcbf
        case 00256: ldst4("lbzx", 1, 1, 0); break;                           // lbzx
        case 00320: if(DIS_RB) ill();                                       // negx
                    else integer3("neg", 'X', DAB_D|DAB_A); break;
        case 00321: if(DIS_RB) ill();
                    else integer3("neg.", 'X', DAB_D|DAB_A); break;
        case 00320|OE: if(DIS_RB) ill();
                    else integer3("nego", 'X', DAB_D|DAB_A); break;
        case 00321|OE: if(DIS_RB) ill();
                    else integer3("nego.", 'X', DAB_D|DAB_A); break;
        case 00356: ldst3("lbzux", 1, 1); break;                             // lbzux
        case 00370:                                                         // norx
#ifdef SIMPLIFIED
                    if(DIS_RS == DIS_RB) { integer3("not", 'Z', ASB_A|ASB_S); o->iclass |= PPC_DISA_SIMPLIFIED; }
                    else
#endif
                    integer3("nor", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 00371: integer3("nor.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 00420: integer3("subfe", 'X', DAB_D|DAB_A|DAB_B); break;        // subfex
        case 00420|OE: integer3("subfeo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00421: integer3("subfe.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00421|OE: integer3("subfeo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00424: integer3("adde", 'X', DAB_D|DAB_A|DAB_B); break;         // addex
        case 00424|OE: integer3("addeo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00425: integer3("adde.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00425|OE: integer3("addeo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00440: mtcrf(); break;                                         // mtcrf
#ifdef POWERPC_32
        case 00444: if(DIS_RA || DIS_RB) ill();                             // mtmsr
                    else { integer3("mtmsr", 'X', DAB_D); o->iclass = PPC_DISA_OEA | PPC_DISA_BRIDGE; } break;
#endif
        case 00455: ldst4("stwcx.", 1, 0, 0); break;                         // stwcx.
        case 00456: ldst4("stwx", 1, 0, 0); break;                           // stwx
        case 00556: ldst4("stwux", 1, 0, 0); break;                          // stwux
        case 00620: if(DIS_RB) ill();                                       // subfzex
                    else integer3("subfze", 'X', DAB_D|DAB_A); break;
        case 00620|OE: if(DIS_RB) ill();
                    else integer3("subfzeo", 'X', DAB_D|DAB_A); break;
        case 00621: if(DIS_RB) ill();
                    else integer3("subfze.", 'X', DAB_D|DAB_A); break;
        case 00621|OE: if(DIS_RB) ill();
                    else integer3("subfzeo.", 'X', DAB_D|DAB_A); break;
        case 00624: if(DIS_RB) ill();                                       // addzex
                    else integer3("addze", 'X', DAB_D|DAB_A); break;
        case 00624|OE: if(DIS_RB) ill();
                    else integer3("addzeo", 'X', DAB_D|DAB_A); break;
        case 00625: if(DIS_RB) ill();
                    else integer3("addze.", 'X', DAB_D|DAB_A); break;
        case 00625|OE: if(DIS_RB) ill();
                    else integer3("addzeo.", 'X', DAB_D|DAB_A); break;
#ifdef POWERPC_32
        case 00644: movesr("mtsr", 0, 0, 0); break;                         // mtsr
#endif
        case 00656: ldst4("stbx", 1, 0, 0); break;                           // stbx
        case 00720: if(DIS_RB) ill();                                       // subfmex
                    else integer3("subfme", 'X', DAB_D|DAB_A); break;
        case 00720|OE: if(DIS_RB) ill();
                    else integer3("subfmeo", 'X', DAB_D|DAB_A); break;
        case 00721: if(DIS_RB) ill();
                    else integer3("subfme.", 'X', DAB_D|DAB_A); break;
        case 00721|OE: if(DIS_RB) ill();
                    else integer3("subfmeo.", 'X', DAB_D|DAB_A); break;
        case 00724: if(DIS_RB) ill();                                       // addmex
                    else integer3("addme", 'X', DAB_D|DAB_A); break;
        case 00724|OE: if(DIS_RB) ill();
                    else integer3("addmeo", 'X', DAB_D|DAB_A); break;
        case 00725: if(DIS_RB) ill();
                    else integer3("addme.", 'X', DAB_D|DAB_A); break;
        case 00725|OE: if(DIS_RB) ill();
                    else integer3("addmeo.", 'X', DAB_D|DAB_A); break;
        case 00726: integer3("mullw", 'X', DAB_D|DAB_A|DAB_B); break;        // mullwx
        case 00726|OE: integer3("mullwo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00727: integer3("mullw.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 00727|OE: integer3("mullwo.", 'X', DAB_D|DAB_A|DAB_B); break;
#ifdef POWERPC_32
        case 00744: movesr("mtsrin", 0, 0, 1); break;                       // mtsrin
#endif
        case 00754: cache1("dcbtst"); break;                                 // dcbtst
        case 00756: ldst4("stbux", 1, 0, 0); break;                          // stbux
        case 01024: integer3("add", 'X', DAB_D|DAB_A|DAB_B); break;          // addx
        case 01024|OE: integer3("addo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01025: integer3("add.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01025|OE: integer3("addo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01054: cache1("dcbt"); break;                                   // dcbt
        case 01056: ldst2("lhzx", 1); break;                                 // lhzx
        case 01070: integer3("eqv", 'Z', ASB_A|ASB_S|ASB_B); break;          // eqvx
        case 01071: integer3("eqv.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 01144: if(DIS_RD || DIS_RA) ill();                             // tlbie
                    else { integer3("tlbie", 'X', DAB_B); o->iclass = PPC_DISA_OEA | PPC_DISA_OPTIONAL; o->r[0] = o->r[2]; o->r[2] = 0; } break;
        case 01154: integer3("eciwx", 'X', DAB_D|DAB_A|DAB_B); o->iclass = PPC_DISA_OPTIONAL; break; // eciwx
        case 01156: ldst2("lhzux", 1); break;                                // lhzux
        case 01170: integer3("xor", 'Z', ASB_A|ASB_S|ASB_B); break;          // xorx
        case 01171: integer3("xor.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 01246: movespr(1); break;                                      // mfspr
        case 01256: ldst2("lhax", 1); break;                                 // lhax
#if !defined(GEKKO)
        case 01344: put("tlbia", 0x03FFF800, 0, PPC_DISA_OEA | PPC_DISA_OPTIONAL); break; // tlbia
#endif
        case 01346: movetbr(); break;                                       // mftb
        case 01356: ldst2("lhaux", 1); break;                                // lhaux
        case 01456: ldst3("sthx", 1, 0); break;                              // sthx
        case 01470: integer3("orc", 'Z', ASB_A|ASB_S|ASB_B); break;          // orcx
        case 01471: integer3("orc.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 01554: integer3("ecowx", 'X', DAB_D|DAB_A|DAB_B); o->iclass = PPC_DISA_OPTIONAL; break; // ecowx
        case 01556: ldst3("sthux", 1, 0); break;                             // sthux
        case 01570: integer3("or", 'Z', ASB_A|ASB_S|ASB_B); break;           // orx
        case 01571: integer3("or.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 01626: integer3("divwu", 'X', DAB_D|DAB_A|DAB_B); break;        // divwux
        case 01626|OE: integer3("divwuo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01627: integer3("divwu.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01627|OE: integer3("divwuo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01646: movespr(0); break;                                      // mtspr
        case 01654: cache("dcbi", PPC_DISA_OEA); break;                     // dcbi
        case 01670: integer3("nand", 'Z', ASB_A|ASB_S|ASB_B); break;         // nandx
        case 01671: integer3("nand.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 01726: integer3("divw", 'X', DAB_D|DAB_A|DAB_B); break;         // divwx
        case 01726|OE: integer3("divwo", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01727: integer3("divw.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 01727|OE: integer3("divwo.", 'X', DAB_D|DAB_A|DAB_B); break;
        case 02000: mcrxr(); break;                                         // mcrxr
        case 02052: ldst5("lswx", 1, 1, 0, 1); break;                        // lswx
        case 02054: ldst2("lwbrx", 1); break;                                // lwbrx
        case 02056: ldst("lfsx", 1, 1, 0, 0, 1); break;                     // lfsx
        case 02060: integer3("srw", 'Z', ASB_A|ASB_S|ASB_B); break;          // srwx
        case 02061: integer3("srw.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 02154: put("tlbsync", 0x03FFF800, 0, PPC_DISA_OEA | PPC_DISA_OPTIONAL); break; // tlbsync
        case 02156: ldst("lfsux", 1, 1, 0, 0, 1); break;                    // lfsux
#ifdef POWERPC_32
        case 02246: movesr("mfsr", 1, 0, 0); break;                         // mfsr
#endif
        case 02252: lsswi("lswi"); break;                                   // lswi
        case 02254: put3("sync", 0x03FFF800, 0); break;                      // sync
        case 02256: ldst("lfdx", 1, 1, 0, 0, 1); break;                     // lfdx
        case 02356: ldst("lfdux", 1, 1, 0, 0, 1); break;                    // lfdux
#ifdef POWERPC_32
        case 02446: movesr("mfsrin", 1, 0, 1); break;                       // mfsrin
#endif
        case 02452: ldst5("stswx", 1, 1, 0, 1); break;                       // stswx
        case 02454: ldst3("stwbrx", 1, 0); break;                            // stwbrx
        case 02456: ldst("stfsx", 1, 1, 0, 0, 1); break;                    // stfsx
        case 02556: ldst("stfsux", 1, 1, 0, 0, 1); break;                   // stfsux
        case 02652: lsswi("stswi"); break;                                  // stswi
        case 02656: ldst("stfdx", 1, 1, 0, 0, 1); break;                    // stfdx
#if !defined(GEKKO)
        case 02754: cache("dcba", PPC_DISA_OPTIONAL); break;                // dcba
#endif
        case 02756: ldst("stfdux", 1, 1, 0, 0, 1); break;                   // stfdux
        case 03054: ldst2("lhbrx", 1); break;                                // lhbrx
        case 03060: integer3("sraw", 'Z', ASB_A|ASB_S|ASB_B); break;         // srawx
        case 03061: integer3("sraw.", 'Z', ASB_A|ASB_S|ASB_B); break;
        case 03160: srawi(); break;                                         // srawi
        case 03161: srawi(); break;
        case 03254: put3("eieio", 0x03FFF800, 0); break;                     // eieio
        case 03454: ldst3("sthbrx", 1, 0); break;                            // sthbrx
        case 03464: if(DIS_RB) ill();                                       // extshx
                    else integer("extsh", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 03465: if(DIS_RB) ill();
                    else integer("extsh.", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 03564: if(DIS_RB) ill();                                       // extsbx
                    else integer("extsb", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 03565: if(DIS_RB) ill();
                    else integer("extsb.", 'S', ASB_A|ASB_S, 0,0,0,0,0); break;
        case 03654: cache1("icbi"); break;                                   // icbi
        case 03656: ldst("stfiwx", 1, 1, 0, 0, 1); o->iclass |= PPC_DISA_OPTIONAL; break; // stfiwx
        case 03754: cache1("dcbz"); break;                                   // dcbz
#ifdef POWERPC_64
        case 00022: integer("mulhdu", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break; // mulhdux
        case 00023: integer("mulhdu.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 00052: ldst("ldx", 1, 1, 1); break;                            // ldx
        case 00066: integer("sld", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break; // sldx
        case 00067: integer("sld.", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break;
        case 00152: ldst("ldux", 1, 1, 1); break;                           // ldux
        case 00164: if(DIS_RB) ill();                                       // cntlzdx
                    else integer("cntlzd", 'S', ASB_A|ASB_S, 0,0,0,0,0); o->iclass |= PPC_DISA_64; break;
        case 00165: if(DIS_RB) ill();
                    else integer("cntlzd.", 'S', ASB_A|ASB_S, 0,0,0,0,0); o->iclass |= PPC_DISA_64; break;
        case 00210: trap(1, 0); break;
        case 00222: integer("mulhd", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break; // mulhdx
        case 00223: integer("mulhd.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 00244: movesr("mtsrd", 0, 1, 0); break;                        // mtrsd
        case 00250: ldst("ldarx", 1, 1, 1); break;                          // ldarx
        case 00344: movesr("mtsrdin", 0, 1, 1); break;                      // mtrsdin
        case 00452: ldst("stdx", 1, 0, 1); break;                           // stdx
        case 00544: if(DIS_RA || DIS_RB) ill();                             // mtmsrd
                    else { integer("mtmsrd", 'X', DAB_D); o->iclass = PPC_DISA_OEA | PPC_DISA_64; } break;
        case 00552: ldst("stdux", 1, 0, 1); break;                          // stdux
        case 00655: ldst("stdcx.", 1, 0, 1); break;                         // stdcx.
        case 00722: integer("mulld", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break; // mulldx
        case 00722|OE: integer("mulldo", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 00723: integer("mulld.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 00723|OE: integer("mulldo.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01252: ldst("lwax", 1, 1, 1); break;                           // lwax
        case 01352: ldst("lwaux", 1, 1, 1); break;                          // lwaux
        case 03164: sradi(); break;                                         // sradi
        case 03165: sradi(); break;
        case 03166: sradi(); break;
        case 03167: sradi(); break;
        case 01544: if(DIS_RD || DIS_RA) ill();                             // slbie
                    else { integer("slbie", 'X', DAB_B); o->iclass = PPC_DISA_64 | PPC_DISA_OEA | PPC_DISA_OPTIONAL; o->r[0] = o->r[2]; o->r[2] = 0; } break;
        case 01622: integer("divdu", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break; // divdux
        case 01622|OE: integer("divduo", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01623: integer("divdu.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01623|OE: integer("divduo.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01722: integer("divd", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break; // divdx
        case 01722|OE: integer("divdo", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01723: integer("divd.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01723|OE: integer("divdo.", 'X', DAB_D|DAB_A|DAB_B); o->iclass |= PPC_DISA_64; break;
        case 01744: put("slbia", 0x03FFF800, 0, PPC_DISA_64 | PPC_DISA_OEA | PPC_DISA_OPTIONAL); break; // slbia
        case 02066: integer("srd", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break; // srdx
        case 02067: integer("srd.", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break;
        case 03064: integer("srad", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break; // sradx
        case 03065: integer("srad.", 'Z', ASB_A|ASB_S|ASB_B); o->iclass |= PPC_DISA_64; break;
        case 03664: if(DIS_RB) ill();                                       // extswx
                    else { integer("extsw", 'S', ASB_A|ASB_S, 0,0,0,0,0); o->iclass |= PPC_DISA_64; } break;
        case 03665: if(DIS_RB) ill();
                    else { integer("extsw.", 'S', ASB_A|ASB_S, 0,0,0,0,0); o->iclass |= PPC_DISA_64; } break;
#endif
        default: ill(); break;
    } break;

    /*
     * Extention 3.
    */

#ifdef POWERPC_64
        case 072:
    switch(Instr & 3) {
        case 0: Instr &= ~3; ldst("ld", 0, 1, 1); break;                    // ld
        case 1: Instr &= ~3; ldst("ldu", 0, 1, 1); break;                   // ldu
        case 2: Instr &= ~3; ldst("lwa", 0, 1, 1); break;                   // lwa
        default: ill(); break;
    } break;
#endif

    /*
     * Extention 4.
    */

    #define MASK_D  (0x1F << 21)
    #define MASK_A  (0x1F << 16)
    #define MASK_B  (0x1F << 11)
    #define MASK_C  (0x1F <<  6)
        case 073:
    switch(Instr & 0x3F) {
        case 044: fpu3("fdivs", MASK_C, FPU_DAB); break;                     // fdivsx
        case 045: fpu3("fdivs.", MASK_C, FPU_DAB); break;
        case 050: fpu3("fsubs", MASK_C, FPU_DAB); break;                     // fsubsx
        case 051: fpu3("fsubs.", MASK_C, FPU_DAB); break;
        case 052: fpu3("fadds", MASK_C, FPU_DAB); break;                     // faddsx
        case 053: fpu3("fadds.", MASK_C, FPU_DAB); break;
#if !defined(GEKKO)
        case 054: fpu("fsqrts", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break; // fsqrtsx
        case 055: fpu("fsqrts.", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break;
#endif
        case 060: fpu("fres", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break; // fresx
        case 061: fpu("fres.", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break;
        case 062: fpu3("fmuls", MASK_B, FPU_DAC); break;                     // fmulsx
        case 063: fpu3("fmuls.", MASK_B, FPU_DAC); break;
        case 070: fpu3("fmsubs", 0, FPU_DACB); break;                        // fmsubsx
        case 071: fpu3("fmsubs.", 0, FPU_DACB); break;
        case 072: fpu3("fmadds", 0, FPU_DACB); break;                        // fmaddsx
        case 073: fpu3("fmadds.", 0, FPU_DACB); break;
        case 074: fpu3("fnmsubs", 0, FPU_DACB); break;                       // fnmsubsx
        case 075: fpu3("fnmsubs.", 0, FPU_DACB); break;
        case 076: fpu3("fnmadds", 0, FPU_DACB); break;                       // fnmaddsx
        case 077: fpu3("fnmadds.", 0, FPU_DACB); break;
        default: ill(); break;
    } break;

    /*
     * Extention 5.
    */

#ifdef POWERPC_64
        case 076:
    switch(Instr & 3) {
        case 0: Instr &= ~3; ldst("std", 0, 0, 1); break;                   // std
        case 1: Instr &= ~3; ldst("stdu", 0, 0, 1); break;                  // stdu
        default: ill(); break;
    } break;
#endif

    /*
     * Extention 6.
    */

        case 077:
    switch(Instr & 0x3F) {
        case 000:
        switch(DIS_RC)
        {
            case 0: fcmp("fcmpu"); break;                                   // fcmpu
            case 1: fcmp("fcmpo"); break;                                   // fcmpo
            case 2: mcrfs(); break;                                         // mcrfs
            default: ill(); break;
        }
        break;
        case 014:
        switch(DIS_RC)
        {
            case 1: mtfsb("mtfsb1"); break;                                 // mtfsb1
            case 2: mtfsb("mtfsb0"); break;                                 // mtfsb0
            case 4: mtfsfi(); break;                                        // mtfsfi
            default: ill(); break;
        }
        break;
        case 015:
        switch(DIS_RC)
        {
            case 1: mtfsb("mtfsb1."); break;                                // mtfsb1.
            case 2: mtfsb("mtfsb0."); break;                                // mtfsb0.
            case 4: mtfsfi(); break;                                        // mtfsfi.
            default: ill(); break;
        }
        break;
        case 016:
        switch(DIS_RC)
        {
            case 18: fpu3("mffs", MASK_A|MASK_B, FPU_D); break;              // mffs
            case 22: mtfsf(); break;                                        // mtfsf
            default: ill(); break;
        }
        break;
        case 017:
        switch(DIS_RC)
        {
            case 18: fpu3("mffs.", MASK_A|MASK_B, FPU_D); break;             // mffs.
            case 22: mtfsf(); break;                                        // mtfsf.
            default: ill(); break;
        }
        break;
        case 020:
        switch(DIS_RC)
        {
            case 1: fpu3("fneg", MASK_A, FPU_DB); break;                     // fneg
            case 2: fpu3("fmr", MASK_A, FPU_DB); break;                      // fmr
            case 4: fpu3("fnabs", MASK_A, FPU_DB); break;                    // fnabs
            case 8: fpu3("fabs", MASK_A, FPU_DB); break;                     // fabs
            default: ill(); break;
        }
        break;
        case 021:
        switch(DIS_RC)
        {
            case 1: fpu3("fneg.", MASK_A, FPU_DB); break;                    // fneg
            case 2: fpu3("fmr.", MASK_A, FPU_DB); break;                     // fmr
            case 4: fpu3("fnabs.", MASK_A, FPU_DB); break;                   // fnabs
            case 8: fpu3("fabs.", MASK_A, FPU_DB); break;                    // fabs
            default: ill(); break;
        }
        break;
        case 030:
        switch(DIS_RC)
        {
            case 0: fpu3("frsp", MASK_A, FPU_DB); break;                     // frsp
            default: ill(); break;
        }
        break;
        case 031:
        switch(DIS_RC)
        {
            case 0: fpu3("frsp.", MASK_A, FPU_DB); break;                    // frsp.
            default: ill(); break;
        }
        break;
        case 034:
        switch(DIS_RC)
        {
            case 0: fpu3("fctiw", MASK_A, FPU_DB); break;                    // fctiw
#ifdef POWERPC_64
            case 25: fpu3("fctid", MASK_A, FPU_DB); break;                   // fctid
            case 26: fpu3("fcfid", MASK_A, FPU_DB); break;                   // fcfid
#endif
            default: ill(); break;
        }
        break;
        case 035:
        switch(DIS_RC)
        {
            case 0: fpu3("fctiw.", MASK_A, FPU_DB); break;                   // fctiw.
#ifdef POWERPC_64
            case 25: fpu3("fctid.", MASK_A, FPU_DB); break;                  // fctid.
            case 26: fpu3("fcfid.", MASK_A, FPU_DB); break;                  // fcfid.
#endif
            default: ill(); break;
        }
        break;
        case 036:
        switch(DIS_RC)
        {
            case 0: fpu3("fctiwz", MASK_A, FPU_DB); break;                   // fctiwz
#ifdef POWERPC_64
            case 25: fpu3("fctidz", MASK_A, FPU_DB); break;                  // fctidz
#endif
            default: ill(); break;
        }
        break;
        case 037:
        switch(DIS_RC)
        {
            case 0: fpu3("fctiwz.", MASK_A, FPU_DB); break;                  // fctiwz.
#ifdef POWERPC_64
            case 25: fpu3("fctidz.", MASK_A, FPU_DB); break;                 // fctidz.
#endif
            default: ill(); break;
        }
        break;
        case 044: fpu3("fdiv", MASK_C, FPU_DAB); break;                      // fdivx
        case 045: fpu3("fdiv.", MASK_C, FPU_DAB); break;
        case 050: fpu3("fsub", MASK_C, FPU_DAB); break;                      // fsubx
        case 051: fpu3("fsub.", MASK_C, FPU_DAB); break;
        case 052: fpu3("fadd", MASK_C, FPU_DAB); break;                      // faddx
        case 053: fpu3("fadd.", MASK_C, FPU_DAB); break;
#if !defined(GEKKO)
        case 054: fpu("fsqrt", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break; // fsqrtx
        case 055: fpu("fsqrt.", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break;
#endif
        case 056: fpu("fsel", 0, FPU_DACB, PPC_DISA_OPTIONAL); break;       // fselx
        case 057: fpu("fsel.", 0, FPU_DACB, PPC_DISA_OPTIONAL); break;
        case 062: fpu3("fmul", MASK_B, FPU_DAC); break;                      // fmulx
        case 063: fpu3("fmul.", MASK_B, FPU_DAC); break;
        case 064: fpu("frsqrte", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break; // frsqrtex
        case 065: fpu("frsqrte.", MASK_A|MASK_C, FPU_DB, PPC_DISA_OPTIONAL); break;
        case 070: fpu3("fmsub", 0, FPU_DACB); break;                         // fmsubx
        case 071: fpu3("fmsub.", 0, FPU_DACB); break;
        case 072: fpu3("fmadd", 0, FPU_DACB); break;                         // fmaddx
        case 073: fpu3("fmadd.", 0, FPU_DACB); break;
        case 074: fpu3("fnmsub", 0, FPU_DACB); break;                        // fnmsubx
        case 075: fpu3("fnmsub.", 0, FPU_DACB); break;
        case 076: fpu3("fnmadd", 0, FPU_DACB); break;                        // fnmaddx
        case 077: fpu3("fnmadd.", 0, FPU_DACB); break;
        default: ill(); break;
    } break;

    /*
     ***********************************************************************************
     * GEKKO Extention.
     ***********************************************************************************
    */

#ifdef  GEKKO
        case 004:
            if(((Instr >> 1) & 0x3FF) == 1014)
            {
                cache("dcbz_l", PPC_DISA_SPECIFIC);                         // dcbz_l
            }
            else switch((Instr >> 1) & 0x1f)
            {
            case 0: ps_cmpx((Instr >> 6) & 3); break;                       // ps_cmpXX
            case 6: if(Instr & 0x40) ps_ldstx("lux");                       // ps_lux
                    else ps_ldstx("lx"); break;                             // ps_lx
            case 7: if(Instr & 0x40) ps_ldstx("stux");                      // ps_stux
                    else ps_ldstx("stx"); break;                            // ps_stx
            case 8:
            switch((Instr >> 6) & 0x1f)
            {
                case 1: ps_db("neg", 1); break;                             // ps_negx
                case 2: ps_db("mr", 1); break;                              // ps_mrx
                case 4: ps_db("nabs", 1); break;                            // ps_nabsx
                case 8: ps_db("abs", 1); break;                             // ps_absx
                default: ill(); break;
            } break;
            case 10: ps_dacb("sum0"); break;                                // ps_sum0x
            case 11: ps_dacb("sum1"); break;                                // ps_sum1x
            case 12: ps_dac("muls0"); break;                                // ps_muls0x
            case 13: ps_dac("muls1"); break;                                // ps_muls1x
            case 14: ps_dacb("madds0"); break;                              // ps_madds0x
            case 15: ps_dacb("madds1"); break;                              // ps_madds1x
            case 16:
            switch((Instr >> 6) & 0x1f)
            {
                case 16: ps_dab("merge00", 1); break;                       // ps_merge00x
                case 17: ps_dab("merge01", 1); break;                       // ps_merge11x
                case 18: ps_dab("merge10", 1); break;                       // ps_merge10x
                case 19: ps_dab("merge11", 1); break;                       // ps_merge11x
                default: ill(); break;
            } break;
            case 18: ps_dab("div", 0); break;                                  // ps_divx
            case 20: ps_dab("sub", 0); break;                                  // ps_subx
            case 21: ps_dab("add", 0); break;                                  // ps_addx
            case 23: ps_dacb("sel"); break;                                 // ps_selx
            case 24: ps_db("res", 0); break;                                   // ps_resx
            case 25: ps_dac("mul"); break;                                  // ps_mulx
            case 26: ps_db("rsqrte", 0); break;                                // ps_rsqrtex
            case 28: ps_dacb("msub"); break;                                // ps_msubx
            case 29: ps_dacb("madd"); break;                                // ps_maddx
            case 30: ps_dacb("nmsub"); break;                               // ps_nmsubx
            case 31: ps_dacb("nmadd"); break;                               // ps_nmaddx
            default: ill(); break;
        } break;
        
        case 070: ps_ldst("l"); break;                                      // psq_l
        case 071: ps_ldst("lu"); break;                                     // psq_lu
        case 074: ps_ldst("st"); break;                                     // psq_st
        case 075: ps_ldst("stu"); break;                                    // psq_stu
#endif  /* GEKKO */

        default: ill(); break;
    }

#ifdef  UPPERCASE
    strupr(o->mnemonic);
#endif
}

char *PPCDisasmSimple(u64 pc, u32 instr)
{
    PPCD_CB dis_out;
    static char output[256];

    dis_out.pc = pc;
    dis_out.instr = instr;

    PPCDisasm(&dis_out);
    sprintf(output, "%08llX  %08lX  %-10s %s", pc, instr, dis_out.mnemonic, dis_out.operands);
    return output;
}
