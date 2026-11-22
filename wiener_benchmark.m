% wiener_benchmark.m
% Test bench for filters.m. Loops images/noisy/noise_manifest.csv through
% every Wiener-family denoising method, times each run, scores it against
% the known-clean source, saves per-run denoised PNGs plus a clean/noisy/
% all-methods comparison montage per manifest row, and writes a tabulated
% results CSV.
% See TEST_BENCH_PLAN.md for the design this implements.

clear; clc; close all;

% -----------------------------
% User settings
% -----------------------------

manifestPath = fullfile("images", "noisy", "noise_manifest.csv");
cleanRoot    = "images/clean";
noisyRoot    = "images/noisy";

resultsCsv     = "wiener_benchmark_results.csv";
figureFolder   = "images/figures";
denoisedFolder = "images/denoised";

filterMethods    = ["classical", "fourier", "haar", "daubechies", "meyer", "shearlet", "curvelet"];
daubechiesOrders = [2 4 8];

% -----------------------------
% Setup: create/clear output folders
% -----------------------------

if ~isfolder(denoisedFolder)
    mkdir(denoisedFolder);
end

if ~isfolder(figureFolder)
    mkdir(figureFolder);
end

denoisedFiles = dir(fullfile(denoisedFolder, "*.png"));
for i = 1:numel(denoisedFiles)
    delete(fullfile(denoisedFiles(i).folder, denoisedFiles(i).name));
end

figureFiles = dir(fullfile(figureFolder, "*.png"));
for i = 1:numel(figureFiles)
    delete(fullfile(figureFiles(i).folder, figureFiles(i).name));
end

% -----------------------------
% Load manifest, resolve local paths
% -----------------------------

% Explicit delimiter: the Source/Output columns are slash-heavy absolute
% paths (from a teammate's machine), which fools readtable's delimiter
% auto-detection into treating "/" as a second delimiter alongside ",".
manifest = readtable(manifestPath, "TextType", "string", "Delimiter", ",");
numManifestRows = size(manifest, 1);

imageNames = strings(numManifestRows, 1);
snrTags    = strings(numManifestRows, 1);
cleanPaths = strings(numManifestRows, 1);
noisyPaths = strings(numManifestRows, 1);
validRow   = true(numManifestRows, 1);

for i = 1:numManifestRows
    [~, name, ~] = fileparts(manifest.Source(i));
    imageNames(i) = name;

    noiseType = manifest.NoiseType(i);
    if noiseType == "clean"
        snrFolder  = "snr_original";
        snrTags(i) = "original";
    else
        snrFolder  = "snr_" + sprintf("%g", manifest.TargetSNRdB(i));
        snrTags(i) = sprintf("%g", manifest.TargetSNRdB(i));
    end

    cleanPaths(i) = fullfile(cleanRoot, name + ".tif");
    noisyPaths(i) = fullfile(noisyRoot, noiseType, snrFolder, name + ".png");

    if ~isfile(cleanPaths(i))
        warning("wiener_benchmark:missingClean", ...
            "Skipping manifest row %d: clean file not found: %s", i, cleanPaths(i));
        validRow(i) = false;
    elseif ~isfile(noisyPaths(i))
        warning("wiener_benchmark:missingNoisy", ...
            "Skipping manifest row %d: noisy file not found: %s", i, noisyPaths(i));
        validRow(i) = false;
    end
end

% -----------------------------
% Main loop: manifest row x filter method (x Daubechies order)
% -----------------------------

allResults   = table();
totalElapsed = tic;

for i = 1:numManifestRows
    if ~validRow(i)
        continue
    end

    imageName  = imageNames(i);
    noiseType  = manifest.NoiseType(i);
    targetSnr  = manifest.TargetSNRdB(i);
    achievedSnr = manifest.AchievedSNRdB(i);
    snrTag     = snrTags(i);
    cleanPath  = cleanPaths(i);
    noisyPath  = noisyPaths(i);

    cleanImage = im2double(imread(cleanPath));
    noisyImage = im2double(imread(noisyPath));

    inputMse = mean((cleanImage(:) - noisyImage(:)).^2);

    montageLabels = strings(0, 1);
    montageImages = {};
    montagePsnr   = [];
    montageSsim   = [];

    for m = 1:numel(filterMethods)
        method = filterMethods(m);

        if method == "daubechies"
            orderList = daubechiesOrders;
        else
            orderList = NaN;
        end

        for o = 1:numel(orderList)
            order = orderList(o);

            if method == "daubechies"
                methodLabel = sprintf("daubechies_db%d", order);
            else
                methodLabel = char(method);
            end

            cpuStart  = cputime;
            realTimer = tic;

            try
                if method == "daubechies"
                    [denoised, info] = filters(noisyImage, method, ...
                        NoiseVariance = "auto", DaubechiesOrder = order);
                else
                    [denoised, info] = filters(noisyImage, method, ...
                        NoiseVariance = "auto");
                end
            catch ME
                warning("wiener_benchmark:filterFailed", ...
                    "Filter failed for %s | %s | snr=%s | method=%s | Error: %s", ...
                    imageName, noiseType, snrTag, methodLabel, ME.message);
                continue
            end

            realTime_sec = toc(realTimer);
            cpuTime_sec  = cputime - cpuStart;

            mse      = mean((cleanImage(:) - denoised(:)).^2);
            psnrVal  = psnr(denoised, cleanImage);
            ssimVal  = ssim(denoised, cleanImage);

            if inputMse == 0
                snrImprovement_dB = NaN;
            elseif mse == 0
                snrImprovement_dB = Inf;
            else
                snrImprovement_dB = 10 * log10(inputMse / mse);
            end

            baseName         = string(sprintf("%s_%s_snr%s_%s", imageName, noiseType, snrTag, methodLabel));
            denoisedFileName = baseName + ".png";
            denoisedPath     = fullfile(denoisedFolder, denoisedFileName);
            imwrite(denoised, denoisedPath);

            if method == "daubechies"
                daubechiesOrderOut = order;
            else
                daubechiesOrderOut = NaN;
            end

            row = table( ...
                string(baseName), imageName, noiseType, targetSnr, achievedSnr, ...
                cleanPath, noisyPath, size(cleanImage, 1), size(cleanImage, 2), ...
                method, daubechiesOrderOut, string(info.engine), ...
                info.noiseVarianceUsed, string(info.noiseVarianceSource), ...
                inputMse, mse, psnrVal, ssimVal, snrImprovement_dB, ...
                cpuTime_sec, realTime_sec, string(denoisedPath), ...
                'VariableNames', { ...
                    'TestName', 'ImageName', 'NoiseType', 'TargetSNR_dB', 'AchievedSNR_dB', ...
                    'CleanFile', 'NoisyFile', 'ImageRows', 'ImageCols', ...
                    'Method', 'DaubechiesOrder', 'Engine', ...
                    'NoiseVarianceUsed', 'NoiseVarianceSource', ...
                    'InputMSE', 'OutputMSE', 'PSNR_dB', 'SSIM', 'SNR_Improvement_dB', ...
                    'CPUTime_sec', 'RealTime_sec', 'DenoisedImagePath' ...
                } ...
            );

            allResults = [allResults; row];

            montageLabels(end + 1, 1) = methodLabel; %#ok<AGROW>
            montageImages{end + 1}    = denoised; %#ok<AGROW>
            montagePsnr(end + 1)      = psnrVal; %#ok<AGROW>
            montageSsim(end + 1)      = ssimVal; %#ok<AGROW>

            fprintf("Finished %-45s | elapsed %7.1fs total | PSNR=%6.2f dB | SSIM=%.4f\n", ...
                baseName, toc(totalElapsed), psnrVal, ssimVal);
        end
    end

    if ~isempty(montageImages)
        try
            if ~isfolder(figureFolder)
                mkdir(figureFolder);
            end

            figPath = fullfile(figureFolder, sprintf("%s_%s_snr%s_compare.png", imageName, noiseType, snrTag));

            numPanels = 2 + numel(montageImages);
            numCols   = 4;
            numRows   = ceil(numPanels / numCols);

            fig = figure("Visible", "off");
            t = tiledlayout(fig, numRows, numCols, "TileSpacing", "compact", "Padding", "compact");

            nexttile(t);
            imshow(cleanImage);
            title("Clean");

            nexttile(t);
            imshow(noisyImage);
            title("Noisy");

            for k = 1:numel(montageImages)
                nexttile(t);
                imshow(montageImages{k});
                title(sprintf("%s\nPSNR=%.2f dB, SSIM=%.4f", montageLabels(k), montagePsnr(k), montageSsim(k)));
            end

            title(t, sprintf("%s | %s noise, SNR=%g dB", imageName, noiseType, targetSnr));

            exportgraphics(fig, figPath);
            close(fig);
        catch figME
            if exist("fig", "var") && isvalid(fig)
                close(fig);
            end
            warning("wiener_benchmark:montageFailed", ...
                "Comparison montage failed for %s | %s | Error: %s", ...
                imageName, noiseType, figME.message);
        end
    end
end

% -----------------------------
% Write CSV
% -----------------------------

if ~isempty(allResults)
    allResults = sortrows(allResults, ...
        {'ImageName', 'NoiseType', 'TargetSNR_dB', 'Method', 'DaubechiesOrder'});

    writetable(allResults, resultsCsv);

    fprintf("\nResults written to: %s\n", resultsCsv);
    fprintf("Denoised images written to: %s\n", denoisedFolder);
    fprintf("Comparison figures written to: %s\n", figureFolder);
else
    warning("wiener_benchmark:noResults", "No results were generated.");
end
