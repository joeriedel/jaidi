//
// This file was auto-generated using the following command:
//
// jai modules/engine/vendor/NukedOPL3/generate.jai
//
// SPDX-License-Identifier: GPL-2.0-or-later


OPL_ENABLE_STEREOEXT :: 0;

OPL_WRITEBUF_SIZE :: 1024;
OPL_WRITEBUF_DELAY :: 2;

opl3_slot :: _opl3_slot;
opl3_channel :: _opl3_channel;
opl3_chip :: _opl3_chip;

_opl3_slot :: struct {
    channel:      *opl3_channel;
    chip:         *opl3_chip;
    out:          s16;
    fbmod:        s16;
    mod:          *s16;
    prout:        s16;
    eg_rout:      u16;
    eg_out:       u16;
    eg_inc:       u8;
    eg_gen:       u8;
    eg_rate:      u8;
    eg_ksl:       u8;
    trem:         *u8;
    reg_vib:      u8;
    reg_type:     u8;
    reg_ksr:      u8;
    reg_mult:     u8;
    reg_ksl:      u8;
    reg_tl:       u8;
    reg_ar:       u8;
    reg_dr:       u8;
    reg_sl:       u8;
    reg_rr:       u8;
    reg_wf:       u8;
    key:          u8;
    pg_reset:     u32;
    pg_phase:     u32;
    pg_phase_out: u16;
    slot_num:     u8;
}

_opl3_channel :: struct {
    slotz:     [2] *opl3_slot; /*Don't use "slots" keyword to avoid conflict with Qt applications*/
    pair:      *opl3_channel;
    chip:      *opl3_chip;
    out:       [4] *s16;

    chtype:    u8;
    f_num:     u16;
    f_num_reg: u16;
    block:     u8;
    block_reg: u8;
    fb:        u8;
    con:       u8;
    alg:       u8;
    ksv:       u8;
    cha:       u16;
    chb:       u16;
    chc:       u16;
    chd:       u16;
    ch_num:    u8;
}

_opl3_writebuf :: struct {
    time: u64;
    reg:  u16;
    data: u8;
}

opl3_writebuf :: _opl3_writebuf;

_opl3_chip :: struct {
    channel:            [18] opl3_channel;
    slot:               [36] opl3_slot;
    timer:              u16;
    eg_timer:           u64;
    eg_timerrem:        u8;
    eg_state:           u8;
    eg_add:             u8;
    eg_timer_lo:        u8;
    newm:               u8;
    nts:                u8;
    rhy:                u8;
    vibpos:             u8;
    vibshift:           u8;
    tremolo:            u8;
    tremolopos:         u8;
    tremoloshift:       u8;
    noise:              u32;
    zeromod:            s16;
    mixbuff:            [4] s32;
    rm_hh_bit2:         u8;
    rm_hh_bit3:         u8;
    rm_hh_bit7:         u8;
    rm_hh_bit8:         u8;
    rm_tc_bit3:         u8;
    rm_tc_bit5:         u8;

    /* OPL3L */
    rateratio:          s32;
    samplecnt:          s32;
    oldsamples:         [4] s16;
    samples:            [4] s16;

    writebuf_samplecnt: u64;
    writebuf_cur:       u32;
    writebuf_last:      u32;
    writebuf_lasttime:  u64;
    writebuf:           [1024] opl3_writebuf;
}

OPL3_Generate :: (chip: *opl3_chip, buf: *s16) -> void #foreign nukedopl3;
OPL3_GenerateResampled :: (chip: *opl3_chip, buf: *s16) -> void #foreign nukedopl3;
OPL3_Reset :: (chip: *opl3_chip, samplerate: u32) -> void #foreign nukedopl3;
OPL3_WriteReg :: (chip: *opl3_chip, reg: u16, v: u8) -> void #foreign nukedopl3;
OPL3_WriteRegBuffered :: (chip: *opl3_chip, reg: u16, v: u8) -> void #foreign nukedopl3;
OPL3_GenerateStream :: (chip: *opl3_chip, sndptr: *s16, numsamples: u32) -> void #foreign nukedopl3;

OPL3_Generate4Ch :: (chip: *opl3_chip, buf4: *s16) -> void #foreign nukedopl3;
OPL3_Generate4ChResampled :: (chip: *opl3_chip, buf4: *s16) -> void #foreign nukedopl3;
OPL3_Generate4ChStream :: (chip: *opl3_chip, sndptr1: *s16, sndptr2: *s16, numsamples: u32) -> void #foreign nukedopl3;

#scope_file

nukedopl3 :: #library "2026-10-09-765ec96/bin/windows/NukedOPL3";
