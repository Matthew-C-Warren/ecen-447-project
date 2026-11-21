function manifest = image_prep(inputDir, outputDir, options)
%IMAGE_PREP Copies clean images and creates noisy versions for denoising analysis.
%   IMAGE_PREP() opens dialogs to select an input and output directory.
%   manifest = IMAGE_PREP(inputDir, outputDir) processes a folder tree and
%   returns a table describing every generated image.
%
%   Optional name-value settings:
%       TargetSNRdB (default [5 10 20])  SNR levels generated in one run
%       Recursive   (default true)
%
%   Generated folders: clean, white, gaussian, rayleigh, exponential, uniform.
%   Noise outputs are grouped below each folder as snr_5, snr_10, and snr_20.

arguments
    inputDir (1,:) char = ""
    outputDir (1,:) char = ""
    options.TargetSNRdB (1,:) double {mustBeFinite, mustBeReal} = [5 10 20]
    options.Recursive (1,1) logical = true
end

if strlength(inputDir) == 0
    inputDir = uigetdir(pwd, "Select folder containing source images");
    if isequal(inputDir, 0)
        return
    end
end

if strlength(outputDir) == 0
    outputDir = uigetdir(pwd, "Select or create the output folder");
    if isequal(outputDir, 0)
        return
    end
end

inputDir = convertStringsToChars(inputDir);
outputDir = convertStringsToChars(outputDir);

if ~isfolder(inputDir)
    error("Input folder does not exist: %s", inputDir);
end

noiseFolders = ["clean", "white", "gaussian", "rayleigh", "exponential", "uniform"];
for i = 1:numel(noiseFolders)
    baseFolder = fullfile(outputDir, noiseFolders(i));
    mkdir(baseFolder);

    if noiseFolders(i) == "clean"
        mkdir(fullfile(baseFolder, "snr_original"));
    else
        for snrIndex = 1:numel(options.TargetSNRdB)
            mkdir(fullfile(baseFolder, snrLabel(options.TargetSNRdB(snrIndex))));
        end
    end
end

files = findImages(inputDir, options.Recursive);
if isempty(files)
    error("No supported image files were found in %s", inputDir);
end

records = table('Size',[0 5], ...
    'VariableTypes',{'string','string','string','double','double'}, ...
    'VariableNames',{'Source','NoiseType','Output','TargetSNRdB','AchievedSNRdB'});

fprintf("Processing %d images...\n", numel(files));
for i = 1:numel(files)
    sourcePath = files{i};
    [~, name, ~] = fileparts(sourcePath);
    relativePath = string(strrep(sourcePath, [inputDir filesep], ""));
    [relativeDir, ~, ~] = fileparts(relativePath);

    [imageData, map, alpha] = imread(sourcePath);
    if ~isempty(map)
        imageData = ind2rgb(imageData, map);
    end

    imageData = normalizeImage(imageData);

    outputSubdir = relativeDir;
    cleanPath = makeOutputPath(outputDir, "clean", outputSubdir, name, "original");
    imwriteWithAlpha(imageData, alpha, cleanPath);

    records = [records
        makeRecord(sourcePath, "clean", cleanPath, 0, Inf)];

    for snrIndex = 1:numel(options.TargetSNRdB)
        targetSNRdB = options.TargetSNRdB(snrIndex);
        seed = randi([1, 2147483646], 1, 1);

        rng(seed);
        [whiteImage, ~] = addNoiseAtSNR(imageData, randn(size(imageData)), targetSNRdB);
        saveNoisyOutput(outputDir, "white", outputSubdir, name, whiteImage, alpha, targetSNRdB);

        rng(seed + 1);
        [gaussianImage, ~] = addNoiseAtSNR(imageData, randn(size(imageData)), targetSNRdB);
        saveNoisyOutput(outputDir, "gaussian", outputSubdir, name, gaussianImage, alpha, targetSNRdB);

        rng(seed + 2);
        u = rand(size(imageData));
        rawRayleigh = sqrt(-2 * log(1 - u));
        rawRayleigh = rawRayleigh - mean(rawRayleigh(:));
        [rayleighImage, ~] = addNoiseAtSNR(imageData, rawRayleigh, targetSNRdB);
        saveNoisyOutput(outputDir, "rayleigh", outputSubdir, name, rayleighImage, alpha, targetSNRdB);

        rng(seed + 3);
        u = rand(size(imageData));
        rawExponential = -log(1 - u);
        rawExponential = rawExponential - mean(rawExponential(:));
        [exponentialImage, ~] = addNoiseAtSNR(imageData, rawExponential, targetSNRdB);
        saveNoisyOutput(outputDir, "exponential", outputSubdir, name, exponentialImage, alpha, targetSNRdB);

        rng(seed + 4);
        [uniformImage, ~] = addNoiseAtSNR(imageData, 2 * rand(size(imageData)) - 1, targetSNRdB);
        saveNoisyOutput(outputDir, "uniform", outputSubdir, name, uniformImage, alpha, targetSNRdB);

        records = [records
            makeRecord(sourcePath, "white", makeOutputPath(outputDir, "white", outputSubdir, name, targetSNRdB), targetSNRdB, calculateSNR(imageData, whiteImage))
            makeRecord(sourcePath, "gaussian", makeOutputPath(outputDir, "gaussian", outputSubdir, name, targetSNRdB), targetSNRdB, calculateSNR(imageData, gaussianImage))
            makeRecord(sourcePath, "rayleigh", makeOutputPath(outputDir, "rayleigh", outputSubdir, name, targetSNRdB), targetSNRdB, calculateSNR(imageData, rayleighImage))
            makeRecord(sourcePath, "exponential", makeOutputPath(outputDir, "exponential", outputSubdir, name, targetSNRdB), targetSNRdB, calculateSNR(imageData, exponentialImage))
            makeRecord(sourcePath, "uniform", makeOutputPath(outputDir, "uniform", outputSubdir, name, targetSNRdB), targetSNRdB, calculateSNR(imageData, uniformImage))];
    end

    fprintf("  [%d/%d] %s\n", i, numel(files), name);
end

manifestPath = fullfile(outputDir, "noise_manifest.csv");
writetable(records, manifestPath);
manifest = records;
fprintf("Done. Wrote %d source/noise records to %s\n", height(records), manifestPath);
end

function files = findImages(inputDir, recursive)
formats = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif"];
if recursive
    entries = dir(fullfile(inputDir, "**", "*"));
else
    entries = dir(fullfile(inputDir, "*"));
end
files = {};
for i = 1:numel(entries)
    if entries(i).isdir
        continue
    end
    [~, ~, ext] = fileparts(entries(i).name);
    if ismember(lower(ext), formats)
        files{end+1} = fullfile(entries(i).folder, entries(i).name); %#ok<AGROW>
    end
end
end

function imageData = normalizeImage(imageData)
if isinteger(imageData)
    imageData = im2double(imageData);
elseif ~isa(imageData, "double")
    imageData = double(imageData) / 255;
else
    imageData = max(0, min(1, imageData));
end
end

function imwriteWithAlpha(imageData, alpha, outputPath)
if isempty(alpha)
    imwrite(imageData, outputPath);
else
    imwrite(imageData, alpha, outputPath);
end
end

function outputPath = makeOutputPath(outputDir, typeName, relativeDir, name, snrValue)
if ischar(snrValue) || isstring(snrValue)
    snrFolder = "snr_" + string(snrValue);
else
    snrFolder = snrLabel(snrValue);
end
folder = fullfile(outputDir, typeName, snrFolder, relativeDir);
mkdir(folder);
outputPath = fullfile(folder, name + ".png");
end

function saveNoisyOutput(outputDir, typeName, relativeDir, name, imageData, alpha, targetSNRdB)
outputPath = makeOutputPath(outputDir, typeName, relativeDir, name, targetSNRdB);
imwriteWithAlpha(imageData, alpha, outputPath);
end

function makeRecord = makeRecord(sourcePath, noiseType, outputPath, targetSNRdB, achievedSNRdB)
makeRecord = table(string(sourcePath), string(noiseType), string(outputPath), ...
    double(targetSNRdB), double(achievedSNRdB), ...
    'VariableNames', {'Source','NoiseType','Output','TargetSNRdB','AchievedSNRdB'});
end

function snr = calculateSNR(cleanImage, noisyImage)
noisePower = mean((cleanImage(:) - noisyImage(:)).^2);
if noisePower <= eps
    snr = Inf;
else
    snr = 10 * log10(mean(cleanImage(:).^2) / noisePower);
end
end

function [noisyImage, actualSNR] = addNoiseAtSNR(cleanImage, rawNoise, targetSNRdB)
signalRMS = sqrt(mean(cleanImage(:).^2));
desiredNoiseRMS = signalRMS / (10^(targetSNRdB / 20));

lowerScale = 0;
upperScale = 1;
while true
    upperCandidate = max(0, min(1, cleanImage + upperScale * rawNoise));
    if rms(cleanImage(:) - upperCandidate(:)) >= desiredNoiseRMS
        break
    end
    upperScale = upperScale * 2;
    if upperScale > 1e6
        break
    end
end

for iteration = 1:30
    midScale = (lowerScale + upperScale) / 2;
    candidate = max(0, min(1, cleanImage + midScale * rawNoise));
    candidateNoiseRMS = rms(cleanImage(:) - candidate(:));

    if candidateNoiseRMS < desiredNoiseRMS
        lowerScale = midScale;
    else
        upperScale = midScale;
    end
end

noisyImage = max(0, min(1, cleanImage + midScale * rawNoise));
actualSNR = calculateSNR(cleanImage, noisyImage);
end

function label = snrLabel(snrValue)
label = "snr_" + sprintf("%g", snrValue);
end
