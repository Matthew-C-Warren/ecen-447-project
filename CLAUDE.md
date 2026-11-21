# ECEN 447 Project

MATLAB project comparing Wiener-family denoising filters on noised
greyscale test images (classic Gonzalez & Woods DIP textbook figures).

## Structure

- `image_prep.m` — takes clean source images, generates noisy versions at
  controlled SNR (5/10/20 dB) across six noise types (white, gaussian,
  rayleigh, exponential, uniform; "clean" = untouched copy), and writes
  `images/noisy/noise_manifest.csv` mapping each noisy output back to its
  clean source and achieved SNR.
- `images/clean/` — original source images (`.tif`).
- `images/noisy/<noise_type>/snr_<N>/*.png` — generated noisy images.
- `filters.m` — implements the 7 Wiener-family denoising filters compared
  in this project (classical, fourier, haar, daubechies, meyer, shearlet,
  curvelet). See `Wiener_Plan.md` for the full design rationale.
- `Wiener_Plan.md` — design plan for `filters.m`: API, per-filter algorithm
  notes, required toolboxes, risks.

No benchmark/driver script exists yet — the plan (`Wiener_Plan.md` §9)
sketches one that would loop `noise_manifest.csv`, call `filters.m`, and
track PSNR/SSIM/execution time per filter.

## Known caveats in `filters.m` (verify before trusting results)

- **Not executed yet.** No MATLAB or Octave is available in this dev
  environment, so `filters.m` has only been checked by hand (block
  structure, API signatures) — it has not actually been run. Run it on a
  real image before relying on its output.
- **Shearlet/curvelet have no real toolbox installed.** Neither ShearLab
  3D / NSST Toolbox nor CurveLab is present on this machine (confirmed by
  search). `filters.m` tries them via `exist()` + `try/catch` and falls
  back to a self-contained Fourier-domain tight-frame transform
  (`multiscaleDirectionalWienerFilter`) when they're missing or error.
  That fallback is a legitimate, Parseval-exact multiscale/directional
  transform, but it is **not** a real shearlet or curvelet transform —
  treat "shearlet"/"curvelet" results as this approximation until the real
  toolboxes are installed and verified on a teammate's machine.
- **CurveLab per-subband noise calibration is a known simplification.**
  The curvelet branch (when the real CurveLab `fdct_wrapping` is present)
  applies the global noise variance to every scale/angle rather than
  CurveLab's documented per-subband calibration constants. This wasn't
  verified against CurveLab's actual normalization — don't trust absolute
  PSNR/SSIM numbers from that branch without checking it.
- **ShearLab calibration (`shearletSystem.RMS`)** is used by convention
  (matches ShearLab's own denoising demo scripts) but, like the CurveLab
  path, was written without being able to run the toolbox to confirm it
  behaves as intended.
- Everything else (classical/fourier/haar/daubechies/meyer) relies only on
  standard, stable MATLAB toolbox functions (`wiener2`, `fft2`/`ifft2`,
  `dwt2`/`idwt2`, `wmaxlev`) and custom logic that was checked by hand for
  correctness (e.g. the wavelet engine records exact subband sizes on the
  way down and crops to them on the way back up, instead of assuming an
  analytic formula) — lower risk, but still unexecuted.
