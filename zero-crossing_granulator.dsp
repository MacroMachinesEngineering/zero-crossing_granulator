// =============================================================================
// This algorithm presents preliminary results for the generation of continuous 
// streams through zero-crossing-synchronous rectangular windowing of 
// non-overlapping sonic fragments. The key feature offered by this design is 
// multimodality: a system that can operate, depending on the parameters, as a 
// looper, wavetable oscillator, or granulator. At this stage of the 
// development, the core mechanism that allows generating streams without major 
// discontinuities is the analysis of first-order and second-order derivatives 
// at the zero-crossing points of input and output signals. The analysis is 
// necessary to guarantee continuity in the first-order and second-order 
// derivative signs at the junction between fragments. The analysis of 
// higher-order derivatives, as well as consistency in the magnitudes of 
// low-order derivatives, is necessary to prevent distortions caused by 
// concatenation. Although, since the author's primary investigation is the 
// musical and formal outcome in deploying this technique, this implementation 
// is a trade-off between accuracy and efficiency to favour CPU-lightness in 
// real-time applications. A first-order and second-order derivative analysis 
// is adequate to prevent audible clicks, while the concatenation artefacts 
// can play a creative role in the musical domain, especially when generating 
// rich spectra through granular processing. On the other hand, an advantage of 
// this design is the absence of comb effects given by overlapping fragments 
// in standard granular techniques.
// =============================================================================

import("stdfaust.lib");

declare name "Zero-Crossing-Synchronous Granulator";
declare author "Dario Sanfilippo";
declare copyright "Copyright (C) 2020 Dario Sanfilippo 
    <sanfilippo.dario@gmail.com>";
declare version "0.30";
declare license "GPL v3.0 license";

// =============================================================================
//      AUXILIARY FUNCTIONS
// =============================================================================

dl(del, in) = de.delay(size, del, in);
grain(del, in) = de.fdelayltv(4, size, del, in);
index = ba.period(size + 1);
lowpass(cf, x) =    +(x * a0) 
                    ~ *(b1)
    with {
        a0 = 1 - b1;
        b1 = exp(-cf * ma.PI);
    };

// =============================================================================
//      MATH
// =============================================================================

diff(x) = x - x';
diff2(x) = diff(x) - diff(x)';
div(x1, x2) = x1 / ba.if(  x2 < 0, 
                           min(ma.EPSILON * -1, x2), 
                           max(ma.EPSILON, x2));
line_reset(rate, reset) =   +(rate / ma.SR) * (1 - (reset != 0))
                            ~ _;
wrap(lower, upper, x) = ma.frac((x - lower) / (upper - lower)) * 
    (upper - lower) + (lower);
zc(x) = x * x' < 0;

// =============================================================================
//      BUFFER SIZE (samples)
// =============================================================================

size = 2 ^ 20;

// =============================================================================
//      LIVE/LOOPED INPUT FUNCTION
// =============================================================================

input(x) =  +(x * rec)
            ~ de.delay(size - 1, size - 1) * (1 - rec);

// =============================================================================
//      GRANULATOR FUNCTION
// =============================================================================

grains_dl_zc(size) =    loop 
                        ~ _
    with {
        // MAIN LOOP
        // Here we define the main feedback mechanism. The algorithm needs
        // to continuously inspect the output to trigger the next grain
        // once a zero-crossing has occurred, after the desired grain
        // duration has passed.
        loop(out, pitch_0, rate_0, position_0, in) =
            (ba.sAndH(trigger(out), zc_index(position, in, out)) + 
                shift(trigger(out)) -
                    ba.sAndH(trigger(out), corr(position, in, out)) : 
                        wrap(0, size + 1)) ,
            in : grain
            with {
                // PARAMETERS SETUP
                // Here we are making sure that parameters are locked to
                // the trigger function and within working ranges.
                pitch = ba.sAndH(trigger(out), pitch_0);
                rate = ba.sAndH(trigger(out), abs(rate_0));
                position = wrap(0, size + 1, position_0);
                // TRIGGER FUNCTION
                // This function is TRUE when the desired grain duration has
                // passed and the output of the granulator is at a 
                // zero-crossing.
                trigger(y) =    loop
                                ~ _
                    with {
                        loop(ready) = zc(y) & 
                            (line_reset(ba.sAndH(1 - 1' + ready, abs(rate_0)), 
                                ready) >= 1);
                    };
                // DIRECTION INVERSION
                // This function keeps track of the sign of the pitch,
                // as the mechanism needs to be adjusted for reverse playback.
                dir = ma.signum(pitch);
                // READING HEAD FUNCTION
                // This function calculates the delay modulation necessary to
                // perform pitch transposition and pitch modulation.
                shift(reset) = div((1 - pitch), rate) *
                    line_reset(ba.sAndH(reset, rate), reset) ^ 
                        p_mod * ma.SR;
                // ZC POSITION FUNCTION
                // Here we calculate the delay that we then sample-and-hold to
                // recall a specific zero-crossing position. Particularly,
                // we are storing zero-crossing positions for positive and 
                // negative first and secondderivatives in four different 
                // delay lines, so that the appropriate ones can be chosen 
                // to keep consistency at grain junctions.
                zc_index(recall, x, y) = index - 
                    ba.if((dir * diff(y) >= 0) & (dir * diff2(y) >= 0), 
                        zc_pp,
                        ba.if((dir * diff(y) >= 0) & (dir * diff2(y) < 0), 
                            zc_pn,
                            ba.if((dir * diff(y) < 0) & (dir * diff2(y) >= 0), 
                                zc_np, zc_nn))) : wrap(0, size + 1)
                    with {
                        zc_pp = dl(recall, ba.sAndH(store, index))
                            with {
                                store = 
                                    zc(x) & (diff(x) >= 0) & (diff2(x) >= 0);
                            };
                        zc_pn = dl(recall, ba.sAndH(store, index))
                            with {
                                store =
                                    zc(x) & (diff(x) >= 0) & (diff2(x) < 0);
                            };
                        zc_np = dl(recall, ba.sAndH(store, index))
                            with {
                                store = 
                                    zc(x) & (diff(x) < 0) & (diff2(x) >= 0);
                            };
                        zc_nn = dl(recall, ba.sAndH(store, index))
                            with {
                                store = 
                                    zc(x) & (diff(x) < 0) & (diff2(x) < 0);
                            };
                    };
                // POSITION CORRECTION FUNCTION
                // Finally, we perform a correction for the position of 
                // the next grain based on the ratio between the derivatives
                // at the junction, so that we can keep continuity when
                // transitioning from a grain with a high slope to a grain
                // with a lower slope.
                corr(recall, x, y) = div(y_diff, x_diff) + ((dir - 1) / 2)
                    with {
                        y_diff = diff(y);
                        x_diff = dl(zc_index(recall, x, y), diff(x));
                    };
            };
    };

// =============================================================================
//      INTERFACE SETTINGS
// =============================================================================

rec = checkbox("[0]Looped/Live");
vol = hslider("[8]Output level", 0, 0, 1, .001) ^ 2;
p = hslider("[2]Pitch factor", -1, -16, 16, .001);
p_mod = pow(16, hslider("[3]Pitch modulation", 0, -1, 1, .001));
r = hslider("[1]Grain rate", 20, 1, 1000, .001);
t = hslider("[4]Time factor", 1, -16, 16, .001);
region = hslider("[5]Buffer region", 0, 0, 1, .001) * size;
asynch(x) = asynch_amount * lowpass(asynch_degree, x);
asynch_amount = hslider("[6]Position self-modulation depth", 0, 0, 1, .001) ^ 
    2 * size * 16;
asynch_degree = hslider("[7]Position self-modulation rate", .5, 0, 1, .001) ^ 4;
pos(x) =    ((+(1 - t) : wrap(0, size + 1)) 
            ~ _) + region + asynch(x);

// =============================================================================
//      MAIN FUNCTION
// =============================================================================

process(x) =    ((p, r, pos, input(x)) : grains_dl_zc(size)) 
                ~ _ : *(vol);
