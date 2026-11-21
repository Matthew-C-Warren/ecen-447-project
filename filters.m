function [denoised, info] = filters(noisyImage, method, options)
%FILTERS Apply a Wiener-family denoising filter to a greyscale image.
%   denoised = FILTERS(noisyImage, method) denoises a double greyscale
%   image in [0,1] using one of:
%       "classical"   spatial local-statistics Wiener filter (wiener2)
%       "fourier"     global frequency-domain MMSE Wiener filter
%       "haar"        wavelet-domain empirical Wiener shrinkage (Haar)
%       "daubechies"  wavelet-domain empirical Wiener shrinkage (dbN)
%       "meyer"       wavelet-domain empirical Wiener shrinkage (discrete Meyer)
%       "shearlet"    shearlet-domain empirical Wiener shrinkage
%       "curvelet"    curvelet-domain empirical Wiener shrinkage
%
%   [denoised, info] = FILTERS(...) also returns a diagnostics struct
%   (noise variance used, elapsed time, which transform engine ran).
%
%   All seven methods are pure denoising filters (no deblurring/PSF).
%   See Wiener_Plan.md for the full design rationale.
%
%   Name-value options:
%       NoiseVariance   (default "auto") numeric, or "auto" for a blind
%                       estimate. Ignored if CleanReference is supplied.
%       CleanReference  (default []) clean image the same size as
%                       noisyImage; when supplied, noise variance is
%                       computed directly (oracle) instead of estimated.
%       WaveletLevel    (default 4) decomposition depth for haar/daubechies/meyer
%       DaubechiesOrder (default 4) one of 2, 4, 8 -> 'db2'/'db4'/'db8'
%       Neighborhood    (default [5 5]) wiener2 window for "classical"
%       NumScales       (default 3) scales for shearlet/curvelet
%       CurveletAngles  (default 8) coarsest-scale angle count for CurveLab
%       ShrinkageWindow (default 7) local-variance window for empirical
%                       Wiener shrinkage (wavelet/shearlet/curvelet)
%
%   Shearlet and curvelet transforms require external toolboxes that are
%   not part of MATLAB (ShearLab / NSST Toolbox, CurveLab). If neither is
%   found on the path, FILTERS falls back to a self-contained multiscale,
%   multidirectional Fourier-domain tight-frame transform that stands in
%   for the real thing (see multiscaleDirectionalWienerFilter below).

arguments
    noisyImage (:,:) double
    method (1,1) string {mustBeMember(method, ...
        ["classical","fourier","haar","daubechies","meyer","shearlet","curvelet"])}
    options.NoiseVariance = "auto"
    options.CleanReference (:,:) double = []
    options.WaveletLevel (1,1) double {mustBeInteger, mustBePositive} = 4
    options.DaubechiesOrder (1,1) double {mustBeMember(options.DaubechiesOrder, [2 4 8])} = 4
    options.Neighborhood (1,2) double {mustBeInteger, mustBePositive} = [5 5]
    options.NumScales (1,1) double {mustBeInteger, mustBePositive} = 3
    options.CurveletAngles (1,1) double {mustBeInteger, mustBePositive} = 8
    options.ShrinkageWindow (1,1) double {mustBeInteger, mustBePositive} = 7
end

startTime = tic;
[noiseVar, varianceSource] = resolveNoiseVariance(noisyImage, options);

waveletNameUsed = "";
engineUsed = "builtin";

switch method
case "classical"
    requireFunction("wiener2", "Install the Image Processing Toolbox.");
    denoised = wiener2(noisyImage, options.Neighborhood, noiseVar);

case "fourier"
    denoised = fourierWienerFilter(noisyImage, noiseVar);

case "haar"
    requireFunction("dwt2", "Install the Wavelet Toolbox.");
    waveletNameUsed = "haar";
    denoised = waveletWienerFilter(noisyImage, char(waveletNameUsed), ...
        options.WaveletLevel, noiseVar, options.ShrinkageWindow);

case "daubechies"
    requireFunction("dwt2", "Install the Wavelet Toolbox.");
    waveletNameUsed = "db" + options.DaubechiesOrder;
    denoised = waveletWienerFilter(noisyImage, char(waveletNameUsed), ...
        options.WaveletLevel, noiseVar, options.ShrinkageWindow);

case "meyer"
    requireFunction("dwt2", "Install the Wavelet Toolbox.");
    waveletNameUsed = "dmey";
    denoised = waveletWienerFilter(noisyImage, char(waveletNameUsed), ...
        options.WaveletLevel, noiseVar, options.ShrinkageWindow);

case "shearlet"
    [denoised, subInfo] = shearletWienerFilter(noisyImage, noiseVar, options);
    engineUsed = subInfo.engine;

case "curvelet"
    [denoised, subInfo] = curveletWienerFilter(noisyImage, noiseVar, options);
    engineUsed = subInfo.engine;
end

denoised = max(0, min(1, denoised));

info = struct( ...
    "method", method, ...
    "noiseVarianceUsed", noiseVar, ...
    "noiseVarianceSource", varianceSource, ...
    "waveletName", waveletNameUsed, ...
    "engine", engineUsed, ...
    "elapsedSeconds", toc(startTime));
end

function requireFunction(name, hint)
if exist(name, "file") ~= 2 && exist(name, "builtin") ~= 5
    error("filters:missingDependency", "%s is required but not found on the path. %s", name, hint);
end
end

function [noiseVar, source] = resolveNoiseVariance(noisyImage, options)
if ~isempty(options.CleanReference)
    if ~isequal(size(options.CleanReference), size(noisyImage))
        error("filters:sizeMismatch", "CleanReference must be the same size as noisyImage.");
    end
    noiseVar = var(noisyImage(:) - options.CleanReference(:));
    source = "oracle";
    return
end

if isnumeric(options.NoiseVariance)
    noiseVar = double(options.NoiseVariance);
    source = "manual";
    return
end

if ~strcmpi(string(options.NoiseVariance), "auto")
    error("filters:badNoiseVariance", "NoiseVariance must be numeric or ""auto"".");
end

sigma = estimateNoiseStd(noisyImage);
noiseVar = sigma^2;
source = "blind";
end

function sigma = estimateNoiseStd(image)
% Donoho's robust MAD estimator on the finest-level Haar diagonal detail,
% used regardless of which wavelet the chosen filter ultimately uses.
[~, ~, ~, cD] = dwt2(image, "haar", "mode", "sym");
sigma = median(abs(cD(:))) / 0.6745;
if sigma <= 0
    sigma = std(image(:)) * 1e-3 + eps;
end
end

function out = empiricalWienerShrink(coeffs, noiseVar, windowSize)
% Local-window empirical Wiener gain: gain = varSignal / (varSignal + varNoise),
% estimated per coefficient from the local energy in a windowSize-by-windowSize
% neighborhood (not a hard/soft threshold -- this is what makes it "Wiener").
kernel = ones(windowSize) / windowSize^2;
localEnergy = conv2(coeffs.^2, kernel, "same");
varSignal = max(localEnergy - noiseVar, 0);
gain = varSignal ./ (varSignal + noiseVar + eps);
out = coeffs .* gain;
end

function out = fourierWienerFilter(noisyImage, noiseVar)
% Global frequency-domain MMSE (Wiener) filter with degradation H = 1
% (denoising only, no deblurring). Sxx is estimated from the noisy
% periodogram minus the assumed-flat noise PSD, clipped at zero.
F = fft2(noisyImage);
noisyPower = abs(F).^2 / numel(noisyImage);
signalPower = max(noisyPower - noiseVar, 0);
H = signalPower ./ (signalPower + noiseVar + eps);
out = real(ifft2(F .* H));
end

function out = waveletWienerFilter(noisyImage, waveletName, level, noiseVar, windowSize)
% Decomposes with repeated dwt2 (not the packed wavedec2/waverec2 format)
% so each detail subband can be shrunk individually and inverted with
% idwt2, recording the exact size at every level to crop border growth
% from the symmetric extension consistently on the way back up.
maxLevel = wmaxlev(size(noisyImage), waveletName);
level = max(1, min(level, maxLevel));

sizes = cell(level + 1, 1);
sizes{1} = size(noisyImage);
cA = noisyImage;
H = cell(level, 1);
V = cell(level, 1);
D = cell(level, 1);

for lev = 1:level
    [cA, cH, cV, cD] = dwt2(cA, waveletName, "mode", "sym");
    sizes{lev + 1} = size(cA);
    H{lev} = empiricalWienerShrink(cH, noiseVar, windowSize);
    V{lev} = empiricalWienerShrink(cV, noiseVar, windowSize);
    D{lev} = empiricalWienerShrink(cD, noiseVar, windowSize);
end

for lev = level:-1:1
    targetSize = sizes{lev};
    cA = idwt2(cA, H{lev}, V{lev}, D{lev}, waveletName, "mode", "sym");
    cA = cA(1:targetSize(1), 1:targetSize(2));
end

out = cA;
end

function [rho, theta] = centeredFrequencyGrid(rows, cols)
% Frequency grid in centered (zero-at-middle) order, matching fftshift
% convention; windows built from this must be ifftshift'ed before being
% multiplied with a raw fft2 output.
rowIdx = (-floor(rows / 2):ceil(rows / 2) - 1) / rows;
colIdx = (-floor(cols / 2):ceil(cols / 2) - 1) / cols;
[colFreq, rowFreq] = meshgrid(colIdx, rowIdx);
rho = sqrt(rowFreq.^2 + colFreq.^2);
theta = mod(atan2(rowFreq, colFreq), pi);
end

function windows = buildDirectionalFrame(rows, cols, numScales, baseDirections, growth)
% Builds a set of smooth, nonnegative, real-valued windows over the 2-D
% Fourier domain (one lowpass + numScales rings of angular wedges) and
% rescales them so sum(window_k.^2) == 1 everywhere -- an exact Parseval
% tight frame. This guarantees perfect reconstruction when the subbands
% are left unmodified, and is the engine behind the shearlet/curvelet
% fallback (see multiscaleDirectionalWienerFilter). "growth" controls how
% many directions each successive scale gets: "double" mimics a real
% shearlet system's dyadic/parabolic scaling (angular resolution doubles
% per scale); "linear" is closer to a curvelet system's angle count,
% which grows roughly linearly with scale.
lowpassCutoff = 0.5 / (numScales + 1);
[rho, theta] = centeredFrequencyGrid(rows, cols);

windows = {exp(-(rho.^2) / (2 * lowpassCutoff^2))};

scaleCenters = linspace(lowpassCutoff * 2, 0.5, numScales);
scaleWidth = (0.5 - lowpassCutoff) / numScales * 0.75;

for s = 1:numScales
    switch growth
    case "double"
        numDir = baseDirections * 2^(s - 1);
    case "linear"
        numDir = baseDirections * s;
    end

    radialBump = exp(-((rho - scaleCenters(s)).^2) / (2 * scaleWidth^2));
    angWidth = (pi / numDir) / 2 * 1.2;

    for d = 1:numDir
        center = (d - 1) * pi / numDir;
        angDiff = abs(mod(theta - center + pi / 2, pi) - pi / 2);
        angularBump = exp(-(angDiff.^2) / (2 * angWidth^2));
        windows{end + 1} = radialBump .* angularBump; %#ok<AGROW>
    end
end

sumSq = zeros(rows, cols);
for k = 1:numel(windows)
    sumSq = sumSq + windows{k}.^2;
end
sumSq = max(sumSq, 1e-6);
for k = 1:numel(windows)
    windows{k} = windows{k} ./ sqrt(sumSq);
end
end

function [out, info] = multiscaleDirectionalWienerFilter(noisyImage, noiseVar, numScales, baseDirections, growth, windowSize)
% Fallback stand-in for a shearlet/curvelet transform: analyzes the image
% with buildDirectionalFrame's tight frame, applies empirical Wiener
% shrinkage per subband (spatial domain), and resynthesizes with the
% frame's adjoint (= itself, since the frame is tight), which is the
% standard analysis/shrink/synthesis pattern used by real shearlet and
% curvelet denoising code.
[rows, cols] = size(noisyImage);
windows = buildDirectionalFrame(rows, cols, numScales, baseDirections, growth);

F = fft2(noisyImage);
Facc = zeros(rows, cols);
for k = 1:numel(windows)
    Wk = ifftshift(windows{k});
    % Parseval: for white noise of variance noiseVar, the spatial-domain
    % noise variance in this subband is noiseVar * mean(|Wk|^2) exactly.
    subbandNoiseVar = noiseVar * mean(Wk(:).^2);
    subband = real(ifft2(F .* Wk));
    shrunk = empiricalWienerShrink(subband, subbandNoiseVar, windowSize);
    Facc = Facc + Wk .* fft2(shrunk);
end

out = real(ifft2(Facc));
info.numSubbands = numel(windows);
end

function [out, info] = shearletWienerFilter(noisyImage, noiseVar, options)
% Prefers ShearLab 3D if it's on the path; falls back to the
% self-contained directional frame (growth = "double", matching a real
% shearlet system's dyadic angular scaling) otherwise or on any error.
info = struct("engine", "fallback");

if exist("SLgetShearletSystem2D", "file") == 2
    try
        [rows, cols] = size(noisyImage);
        shearletSystem = SLgetShearletSystem2D(0, rows, cols, options.NumScales);
        coeffs = SLsheardec2D(noisyImage, shearletSystem);
        for k = 1:size(coeffs, 3)
            % ShearLab's own denoising demos scale the per-subband noise
            % std by shearletSystem.RMS(k); reused here for the Wiener
            % variance (RMS^2) rather than their threshold formula.
            subbandNoiseVar = noiseVar * shearletSystem.RMS(k)^2;
            coeffs(:, :, k) = empiricalWienerShrink(coeffs(:, :, k), subbandNoiseVar, options.ShrinkageWindow);
        end
        out = SLshearrec2D(coeffs, shearletSystem);
        info.engine = "ShearLab";
        return
    catch err
        warning("filters:shearletToolboxFailed", ...
            "ShearLab call failed (%s); falling back to the built-in directional-frame approximation.", err.message);
    end
end

[out, fallbackInfo] = multiscaleDirectionalWienerFilter(noisyImage, noiseVar, options.NumScales, 4, "double", options.ShrinkageWindow);
info.numSubbands = fallbackInfo.numSubbands;
end

function [out, info] = curveletWienerFilter(noisyImage, noiseVar, options)
% Prefers CurveLab's fdct_wrapping if it's on the path; falls back to the
% self-contained directional frame (growth = "linear", matching a
% curvelet system's angle count growing with scale) otherwise or on any
% error. NOTE: the per-scale/angle noise-variance calibration below uses
% the global noiseVar unscaled -- CurveLab coefficients are not unit-norm
% either, and the exact scaling constants should be calibrated against
% CurveLab's own documented normalization before trusting absolute
% results from this branch.
info = struct("engine", "fallback");

if exist("fdct_wrapping", "file") == 2
    try
        isReal = 1;
        finest = 1;
        C = fdct_wrapping(noisyImage, isReal, finest, options.NumScales, options.CurveletAngles);
        for s = 1:numel(C)
            for a = 1:numel(C{s})
                C{s}{a} = empiricalWienerShrink(C{s}{a}, noiseVar, options.ShrinkageWindow);
            end
        end
        [rows, cols] = size(noisyImage);
        out = real(ifdct_wrapping(C, isReal, rows, cols));
        info.engine = "CurveLab";
        return
    catch err
        warning("filters:curveletToolboxFailed", ...
            "CurveLab call failed (%s); falling back to the built-in directional-frame approximation.", err.message);
    end
end

[out, fallbackInfo] = multiscaleDirectionalWienerFilter(noisyImage, noiseVar, options.NumScales, 6, "linear", options.ShrinkageWindow);
info.numSubbands = fallbackInfo.numSubbands;
end
