require 'torch'
require 'xlua'
require 'sys'
require 'image'
require 'nnx'
require 'opticalflow_model'
require 'groundtruth_opticalflow'
require 'openmp'
require 'score_opticalflow'
require 'download_model'

torch.manualSeed(1)

op = xlua.OptionParser('%prog [options]')
op:option{'-i1', '--input-image1', action='store', dest='input_image1',
	  help='First image for the optical flow'}
op:option{'-i2', '--input-image2', action='store', dest='input_image2',
	  help='Second image for the optical flow'}
op:option{'-i', '--input-model', action='store', dest='input_model',
	  help='Trained convnet, this option isn\'t used if -dldir is used'}
op:option{'-nt', '--num-threads', action='store', dest='nThreads', default=2,
	  help='Number of threads used'}
op:option{'-p', '--post-process-win-size', action='store', dest='post_process_winsize',
	  default=1,
	  help='Basic output post-processing window size (1 disables post-processing)'}
op:option{'-dldir', '--download-dir', action='store', dest='download_dir', default=nil,
	  help='scp command to the models folder (eg. mfm352@access.cims.nyu.edu:/depth-estimation/models)'}

opt=op:parse()
opt.nThreads = tonumber(opt.nThreads)
opt.post_process_winsize = tonumber(opt.post_process_winsize)

openmp.setDefaultNumThreads(opt.nThreads)

function displayKernels(geometry, model)
   if geometry.multiscale then
      for i = 1,#geometry.ratios do
	 local matcher = model.modules[2].unfocused_pipeline.modules[i].modules[3]
	 local weight = matcher.modules[1].modules[1].modules[3].modules[1].weight
	 image.display{image=weight, padding=2, zoom=8}
	 if #geometry.layers > 1 then
	    local weight2 = matcher.modules[1].modules[1].modules[3].modules[3].weight
	    weight2 = weight2:reshape(weight2:size(1)*weight2:size(2), weight2:size(3),
				      weight2:size(4))
	    image.display{image=weight2, padding=2, zoom=8}
	 end
      end
   else
      local weight = model.modules[1].modules[1].modules[1].weight
      image.display{image=weight, padding=2, zoom=8}
      if #geometry.layers > 1 then
	 local weight2 = model.modules[1].modules[1].modules[3].weight
	 image.display{image=weight2, padding=2, zoom=8}
      end
   end
end

if opt.download_dir ~= nil then
   opt.input_model = downloadModel(opt.download_dir)
end

geometry, model = loadModel(opt.input_model, true)
if not geometry.maxhGT then
   geometry.maxhGT = geometry.maxh
   geometry.maxwGT = geometry.maxw
end
displayKernels(geometry, model)

local delta = tonumber(opt.input_image2) - tonumber(opt.input_image1)
local image1, image2, gt
if geometry.motion_correction then
   image1 = loadRectifiedImageOpticalFlow(geometry, 'data/', opt.input_image1, nil, nil)
   _,gt,image2,_ = loadRectifiedImageOpticalFlow(geometry, 'data/', opt.input_image2,
						       opt.input_image1, delta)
else
   image1 = loadImageOpticalFlow(geometry, 'data/', opt.input_image1, nil, nil)
   image2,gt = loadImageOpticalFlow(geometry, 'data/', opt.input_image2,
					  opt.input_image1, delta)
end
local input = {image1, image2}
image.display(input)

t = torch.Timer()
if not geometry.multiscale then
   input = prepareInput(geometry, input[1], input[2])
end

local output = model:forward(input)
print(t:time())
outputt = output:clone()
output = processOutput(geometry, output)

local output2 = torch.Tensor(2, output.x:size(1), output.x:size(2)):zero()

if opt.post_process_winsize ~= 1 then
   output2 = postProcessImage(output.full, opt.post_process_winsize)
else
   output2 = output.full
end

nGood, nNear, nBad, d, meanDst, stdDst = evalOpticalflow(geometry, output2, gt)
print('nGood=' .. nGood .. ' nNear=' .. nNear .. ' nBad=' .. nBad)
print(100.*nGood/(nGood+nNear+nBad) .. '% accurate, ' .. 100.*(nGood+nNear)/(nGood+nNear+nBad) .. '% almost accurate')
print('meanDst=' .. meanDst .. ' (std=' .. stdDst .. ')')

local inity, initx = centered2onebased(geometry, 0, 0)
image.display{output2[1], gt[1]}
image.display{output2[2], gt[2]}
print("--")
local hsv = flow2hsv(geometry, output2)
local gthsv = flow2hsv(geometry, gt)
image.display{hsv, gthsv}
image.display{hsv - gthsv}