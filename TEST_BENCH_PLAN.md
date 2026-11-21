# Plan: `wiener_benchmark.m` — Image Denoising Test Bench

## 1. Objective

Port the structure of `../math-414-project/denoising_filter_tests.m` (the
MATH 414 wavelet-audio test bench) to this project: loop over every noisy
test image, run it through each of `filters.m`'s denoising methods, time
each run, score it against the known-clean source, save representative
output figures, and write a tabulated CSV of results. This does **not**
change `filters.m` or `image_prep.m` — it is a new driver script,
`wiener_benchmark.m`, matching the shape already sketched in
`Wiener_Plan.md` §9.

## 2. What carries over from the audio test bench, and what doesn't

| Audio test bench | Image test bench |
|---|---|
| `wavelet_denoising_filter(signal, level, Fs, ...)` | `filters(noisyImage, method, options)` |
| Loop: noisy `.wav` file → regex-parsed sample/SNR → match clean `.wav` | Loop: `images/noisy/noise_manifest.csv` rows → clean/noisy path pair + NoiseType/SNR already given, no regex needed |
| Sweep: 4 wavelets × 14 levels × 2 methods | Sweep: 7 filter methods, with `daubechies` expanded to 3 rows (db2/db4/db8) — **no level sweep** (confirmed below) |
| Metrics: MSE, SNR, SNR improvement, CPU/real time | Metrics: MSE, PSNR, SSIM, SNR improvement, CPU/real time (PSNR/SSIM per `Wiener_Plan.md` §3/§9, which this project's own plan already calls for) |
| Figure per run: input waveform PNG + output waveform PNG | PNG per run for the denoised image (cheap) + a richer clean/noisy/denoised comparison montage for a representative subset only (see §6) |
| Extra "clean signal as input" identity-check loop appended after the main loop | **Not needed as a separate loop** — the manifest already has a `NoiseType == "clean"` row per source image (`AchievedSNRdB = Inf`), which *is* the identity-check case, so it falls out of the normal loop for free |
| try/catch per combination, `warning` + `continue` on failure | Same pattern |
| `writetable(...)` to one results CSV, sorted | Same pattern |

Confirmed design decisions (from your answers):
- **Paths**: rebuild clean/noisy file paths from `NoiseType` + SNR folder +
  filename relative to `images/clean` and `images/noisy`, rather than
  trusting the manifest's stored `Source`/`Output` columns (those are
  absolute paths from a teammate's machine and won't resolve elsewhere).
  The manifest is still the source of truth for *which* (image, noise
  type, SNR) combinations exist and for `AchievedSNRdB` — just not for
  literal file locations.
- **No WaveletLevel sweep.** `haar`/`daubechies`/`meyer` all run at
  `filters.m`'s default `WaveletLevel = 4`. `daubechies` still expands
  into 3 result rows (`DaubechiesOrder` = 2, 4, 8), matching
  `Wiener_Plan.md` §5.4/§9 exactly.
- **Blind noise variance only** (`NoiseVariance = "auto"`) for the full
  grid. Oracle-vs-blind is a single one-off sanity check (§7), not part of
  the main sweep.
- **Figures**: every run writes a plain denoised-image PNG (cheap,
  supports later visual review); a full clean/noisy/denoised comparison
  montage figure is only generated for one representative image
  (`Fig0222(b)(cameraman)`) across all noise types at `snr_10`, to keep
  the ~200+ run grid from generating 400+ heavyweight figure files.

## 3. Grid size

From the manifest: 3 clean images × 6 noise types × 3 SNR levels = 54
noisy image files, plus 3 `clean`/`snr_original` rows (the identity-check
case) = **57 manifest rows** total.

Filter methods per row: `classical`, `fourier`, `haar`, `meyer`,
`shearlet`, `curvelet` (6 methods, 1 row each) + `daubechies` (3 rows:
db2/db4/db8) = **9 result rows per manifest row**.

Total result rows: 57 × 9 = **513 filter runs.**

This is large enough that runtime matters (shearlet/curvelet fallback
transforms are the slowest per `filters.m`'s own `multiscaleDirectionalWienerFilter`
path — see `Wiener_Plan.md` §10 risk). See §8 for a scoped dry run before
committing to the full grid.

## 4. Script structure (`wiener_benchmark.m`)

```matlab
% -----------------------------
% User settings
% -----------------------------
manifestPath   = fullfile("images", "noisy", "noise_manifest.csv");
cleanRoot      = "images/clean";       % NoiseType == "clean" rows resolve here
noisyRoot      = "images/noisy";       % <NoiseType>/snr_<N>/<name>.png

resultsCsv     = "wiener_benchmark_results.csv";
figureFolder   = "images/figures";
denoisedFolder = "images/denoised";

montageImageFilter = "Fig0222(b)(cameraman)";   % representative-figure subset
montageSnr          = 10;

filterMethods = ["classical","fourier","haar","daubechies","meyer","shearlet","curvelet"];
daubechiesOrders = [2 4 8];

% -----------------------------
% Setup: create/clear output folders (mirrors audio script's cleanup block)
% -----------------------------
% mkdir if missing; delete *.png under denoisedFolder/figureFolder from prior runs

% -----------------------------
% Load manifest, resolve local paths
% -----------------------------
manifest = readtable(manifestPath);
% for each row: derive cleanPath from clean image filename (strip the
% manifest's absolute Source dir, keep the basename, resolve against
% cleanRoot) and noisyPath from NoiseType + TargetSNRdB (or "snr_original"
% for NoiseType=="clean") + basename, resolved against noisyRoot.
% Skip + warn on any row whose resolved file doesn't exist (isfile check).

% -----------------------------
% Main loop: manifest row x filter method (x Daubechies order)
% -----------------------------
allResults = table();
for each manifest row
    [cleanImage, noisyImage] = load + normalize (im2double, grayscale)
    for each filterMethods
        if method == "daubechies"
            for each daubechiesOrders  -> run + score + log (3 sub-iterations)
        else
            run + score + log (1 iteration)
    end
end

% Per iteration:
%   cpuStart = cputime; realTimer = tic;
%   try
%       [denoised, info] = filters(noisyImage, method, NoiseVariance="auto", <extra opts>);
%   catch ME
%       warning(...); continue
%   end
%   realTime_sec = toc(realTimer); cpuTime_sec = cputime - cpuStart;
%   mse = mean((cleanImage(:)-denoised(:)).^2);
%   psnrVal = psnr(denoised, cleanImage);
%   ssimVal = ssim(denoised, cleanImage);
%   inputMse = mean((cleanImage(:)-noisyImage(:)).^2);
%   snrImprovement_dB = 10*log10(inputMse/mse);   % guard divide-by-zero like audio script's clean-input branch
%   write denoised PNG to denoisedFolder
%   if row's image/SNR matches the montage subset: build + save clean|noisy|denoised comparison figure
%   append row to allResults

% -----------------------------
% Write CSV
% -----------------------------
% sortrows by ImageName, NoiseType, SNR, Method, (DaubechiesOrder)
% writetable(allResults, resultsCsv)
```

## 5. Results table columns

Mirroring the audio script's `allResults` schema, swapped for image
metrics:

`TestName, ImageName, NoiseType, TargetSNR_dB, AchievedSNR_dB, CleanFile,
NoisyFile, ImageRows, ImageCols, Method, DaubechiesOrder, Engine,
NoiseVarianceUsed, NoiseVarianceSource, InputMSE, OutputMSE, PSNR_dB,
SSIM, SNR_Improvement_dB, CPUTime_sec, RealTime_sec, DenoisedImagePath`

- `Engine` and `NoiseVarianceUsed`/`Source` come straight from `filters.m`'s
  `info` struct (`info.engine`, `info.noiseVarianceUsed`,
  `info.noiseVarianceSource`) — no need to recompute anything it already
  reports.
- `DaubechiesOrder` is empty/`NaN` for all non-daubechies rows.

## 6. Figures

- **Per-run denoised PNG** (`images/denoised/<image>_<noisetype>_snr<N>_<method>[_<order>].png`):
  written for all 513 runs via `imwrite`. Cheap, supports later spot
  checks without needing MATLAB.
- **Comparison montage** (`images/figures/<image>_<noisetype>_compare.png`):
  one 1×3 `subplot` (clean | noisy | denoised, with method name + PSNR/SSIM
  in the title) per `(montageImageFilter, noiseType, montageSnr)` combination
  — 6 noise types × 1 image × 1 SNR = 6 montage figures total, generated as
  `figure("Visible","off")` + `saveas`, same pattern as the audio script.

## 7. One-off sanity checks (not part of the main grid — run manually first)

Straight from `Wiener_Plan.md` §8, since that section already specifies
this project's pre-flight checklist:

1. **Identity check**: confirm the `NoiseType=="clean"` manifest rows score
   near-perfect PSNR/SSIM for all 7 methods (already covered by the main
   loop since those rows exist in the manifest — just check them first
   once results are in).
2. **One image, one noise type, all 7 methods** — run a 1-row-of-manifest
   slice manually, eyeball the montage figure, before launching the full
   loop.
3. **Oracle vs. blind** — call `filters(noisyImage, method,
   CleanReference=cleanImage)` once for a single (image, noise, SNR, method)
   combination and confirm its PSNR ≥ the blind (`"auto"`) run's PSNR for
   the same combination. One-off script snippet, not wired into
   `wiener_benchmark.m`'s main loop or its CSV schema (per your answer in §2).

## 8. Suggested rollout order

1. Write `wiener_benchmark.m` against a **hand-picked 1-row, 1-method**
   slice of the manifest (skip the full loop) to confirm path resolution,
   `filters()` call shape, and metric computation all work before scaling
   up — this is the one actual gap versus the audio script, since
   `filters.m` itself has never been executed (per `CLAUDE.md`'s caveats).
2. Expand to the full 7-method (9-row) sweep on that one manifest row,
   check the montage figure.
3. Run the full 57-row × 9 grid. Expect `shearlet`/`curvelet` to dominate
   runtime (fallback Fourier-domain tight-frame transform, no real
   toolbox installed — see `CLAUDE.md`/`Wiener_Plan.md` §10) — consider
   printing a running elapsed-time total so a runaway case is visible
   before the whole grid finishes.
4. Only after a clean full run, treat `wiener_benchmark_results.csv` as
   trustworthy enough to build report tables/plots from — and even then,
   flag any `shearlet`/`curvelet` rows in analysis as "fallback transform
   approximation," not a real shearlet/curvelet result, per `CLAUDE.md`.

## 9. Repo hygiene

Added a `.gitignore` covering `images/denoised/`, `images/figures/`, and
the results CSV(s) — these are regenerated run outputs (like the audio
project's `denoised_signals/`/`denoising_figures/`), not source material,
and at 500+ files they don't belong in version control. `images/clean/`
and `images/noisy/` stay tracked, as they already are.

## 10. Open items for you to confirm before implementation

- `filters.m` has never actually been executed (per `CLAUDE.md`). The
  rollout order in §8 is deliberately staged so the first real MATLAB run
  of `filters.m` happens on a tiny slice, not the full 513-run grid — if
  something in `filters.m` itself breaks (not just the test bench), better
  to find out early.
- ~~Confirm `images/clean/*.tif` are single-channel greyscale~~ — verified
  via `sips -g all`: all three (`cameraman`, `crowd`,
  `original_pattern`) report `samplesPerPixel: 1`, `space: Gray`. No
  `rgb2gray` gap in `image_prep.m` or needed in the benchmark.
