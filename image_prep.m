function manifest = image_prep(inputDir, outputDir, options)
%IMAGE_PREP Copies clean images and creates noisy versions for denoising analysis.
%   IMAGE_PREP() opens dialogs to select an input and output directory.
%   manifest = IMAGE_PREP(inputDir, outputDir) processes a folder tree and
%   returns a table describing every generated image.
%
%   Optional name-value settings:
%       WhiteSigma        (default 0.05)
%       GaussianSigma     (default 0.05)
%       RayleighSigma     (default 0.05)
%       ExponentialScale  (default 0.05)
%       SaltPepperDensity (default 0.05)
%       UniformAmplitude  (default 0.05)
%       Recursive         (default true)
%
%   Generated folders: clean, white, gaussian, rayleigh, exponential,
%                      salt_pepper, uniform.

arguments
    inputDir (1,:) char = ""
    outputDir (1,:) char = ""
    options.WhiteSigma (1,1) double {mustBeInRange(options.WhiteSigma,0,1)} = 0.05
    options.GaussianSigma (1,1) double {mustBeInRange(options.GaussianSigma,0,1)} = 0.05
    options.RayleighSigma (1,1) double {mustBeInRange(options.RayleighSigma,0,1)} = 0.05
    options.ExponentialScale (1,1) double {mustBeInRange(options.ExponentialScale,0,1)} = 0.05
    options.SaltPepperDensity (1,1) double {mustBeInRange(options.SaltPepperDensity,0,1)} = 0.05
    options.UniformAmplitude (1,1) double {mustBeInRange(options.UniformAmplitude,0,1)} = 0.05
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

noiseFolders = ["clean", "white", "gaussian", "rayleigh", "exponential", "salt_pepper", "uniform"];
for i = 1:numel(noiseFolders)
    mkdir(fullfile(outputDir, noiseFolders(i)));
end

files = findImages(inputDir, options.Recursive);
if isempty(files)
    error("No supported image files were found in %s", inputDir);
end

records = table('Size',[0 5], ...
    'VariableTypes',{'string','string','string','double','double'}, ...
    'VariableNames',{'Source','NoiseType','Output','NoiseParameter','Seed'});

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
    cleanPath = makeOutputPath(outputDir, "clean", outputSubdir, name);
    imwriteWithAlpha(imageData, alpha, cleanPath);

    seed = randi([1, 2147483646], 1, 1);

    rng(seed);
    whiteNoise = randn(size(imageData)) * options.WhiteSigma;
    whiteImage = max(0, min(1, imageData + whiteNoise));
    saveNoisyOutput(outputDir, "white", outputSubdir, name, whiteImage, alpha);

    rng(seed + 1);
    gaussianImage = imnoise(imageData, "gaussian", 0, options.GaussianSigma^2);
    saveNoisyOutput(outputDir, "gaussian", outputSubdir, name, gaussianImage, alpha);

    rng(seed + 2);
    u = rand(size(imageData));
    rayleighNoise = options.RayleighSigma * sqrt(-2 * log(1 - u));
    rayleighImage = max(0, min(1, imageData + rayleighNoise));
    saveNoisyOutput(outputDir, "rayleigh", outputSubdir, name, rayleighImage, alpha);

    rng(seed + 3);
    spImage = imnoise(imageData, "salt & pepper", options.SaltPepperDensity);
    saveNoisyOutput(outputDir, "salt_pepper", outputSubdir, name, spImage, alpha);

    rng(seed + 4);
    uniformNoise = (2 * rand(size(imageData)) - 1) * options.UniformAmplitude;
    uniformImage = max(0, min(1, imageData + uniformNoise));
    saveNoisyOutput(outputDir, "uniform", outputSubdir, name, uniformImage, alpha);

    rng(seed + 5);
    u = rand(size(imageData));
    exponentialNoise = -options.ExponentialScale * log(1 - u);
    exponentialImage = max(0, min(1, imageData + exponentialNoise));
    saveNoisyOutput(outputDir, "exponential", outputSubdir, name, exponentialImage, alpha);

    records = [records
        makeRecord(sourcePath, "clean", cleanPath, 0, seed)
        makeRecord(sourcePath, "white", makeOutputPath(outputDir, "white", outputSubdir, name), options.WhiteSigma, seed)
        makeRecord(sourcePath, "gaussian", makeOutputPath(outputDir, "gaussian", outputSubdir, name), options.GaussianSigma, seed + 1)
        makeRecord(sourcePath, "rayleigh", makeOutputPath(outputDir, "rayleigh", outputSubdir, name), options.RayleighSigma, seed + 2)
        makeRecord(sourcePath, "salt_pepper", makeOutputPath(outputDir, "salt_pepper", outputSubdir, name), options.SaltPepperDensity, seed + 3)
        makeRecord(sourcePath, "uniform", makeOutputPath(outputDir, "uniform", outputSubdir, name), options.UniformAmplitude, seed + 4)
        makeRecord(sourcePath, "exponential", makeOutputPath(outputDir, "exponential", outputSubdir, name), options.ExponentialScale, seed + 5)];

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

function outputPath = makeOutputPath(outputDir, typeName, relativeDir, name)
folder = fullfile(outputDir, typeName, relativeDir);
mkdir(folder);
outputPath = fullfile(folder, name + ".png");
end

function saveNoisyOutput(outputDir, typeName, relativeDir, name, imageData, alpha)
outputPath = makeOutputPath(outputDir, typeName, relativeDir, name);
imwriteWithAlpha(imageData, alpha, outputPath);
end

function makeRecord = makeRecord(sourcePath, noiseType, outputPath, parameter, seed)
makeRecord = table(string(sourcePath), string(noiseType), string(outputPath), ...
    double(parameter), double(seed), ...
    'VariableNames', {'Source','NoiseType','Output','NoiseParameter','Seed'});
end
