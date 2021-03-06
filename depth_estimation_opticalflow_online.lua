require 'torch'
require 'xlua'
require 'opticalflow_model'
require 'opticalflow_model_io'
require 'openmp'
require 'sys'
require 'download_model'
require 'image_loader'

require 'camera'

torch.manualSeed(1)

op = xlua.OptionParser('%prog [options]')
-- general
op:option{'-nt', '--num-threads', action='store', dest='nThreads', default=2,
	  help='Number of threads used'}
-- input
op:option{'-i', '--input-model', action='store', dest='input_model',
	  help='Trained convnet, this option isn\'t used if -dldir is used'}
op:option{'-dldir', '--download-dir', action='store', dest='download_dir', default=nil,
	  help='scp command to the models folder (eg. mfm352@access.cims.nyu.edu:/depth-estimation/models)'}
op:option{'-rd', '--root-directory', action='store', dest='root_directory',
	  default='./data', help='Root dataset directory'}
op:option{'-fi', '--first-image', action='store', dest='first_image', default=0,
	  help='Index of first image used'}
op:option{'-d', '--delta', action='store', dest='delta', default=1,
	  help='Delta between two consecutive frames'}
-- output
op:option{'-do', '--display-output', action='store_true', dest='display_output', default=false,
	  help='Display the computed output'}

opt=op:parse()
opt.nThreads = tonumber(opt.nThreads)
opt.first_image = tonumber(opt.first_image)
opt.delta = tonumber(opt.delta)

openmp.setDefaultNumThreads(opt.nThreads)
if opt.download_dir ~= nil then
   opt.input_model = downloadModel(opt.download_dir)
   if opt.input_model == nil then
      os.exit(0)
   end
end

local loaded = loadModel(opt.input_model, true, true)
local model = loaded.model
local filter = loaded.filter
local geometry = loaded.geometry

local output_window
local timer

local camera = image.Camera{idx=1, fps=30}

-- while true do
-- 	last_im = camera:forward()
-- 	d = image.display{image=last_im, win=d, zoom=1}
-- end

--last_im = camera:forward():sub(1,3,1, 180,1,320)
last_im = image.scale(camera:forward():sub(1,3,1, 360,1,640), 320, 180)
--last_im = camera:forward():sub(1,3,1, 360,1,640)
last_im_filtered = filter:forward(last_im):clone()
local i = 0
while true do
   sys.tic()
   local im = image.scale(camera:forward():sub(1,3,1, 360,1,640), 320, 180)
   --local im = camera:forward():sub(1,3,1,180,1,320)
   image.save(string.format("test/%09d.png", i), im)
   d = image.display{image=im, win=d, zoom=1}
   i = i + 1
   print(i)
   print("FPS: ".. 1/sys.toc())
   --[[
   im_filtered = filter:forward(im):clone()
   if im then
       timer = torch.Timer()

	   local input
	   if geometry.multiscale then
	      input = {}
	      for i = 1,#geometry.ratios do
			input[i] = {last_im_filtered[i], im_filtered[i]}
	      end
	   else
	      input = prepareInput(geometry, last_im_filtered, im_filtered)
	   end

	   local moutput = model:forward(input)
	   local output = processOutput(geometry, moutput)
	   print(timer:time())
	   if opt.display_output then
	      output_window = image.display{image=output.full, win=output_window}
	   end
	   last_im = im
	   last_im_filtered = im_filtered:clone()
	   d = image.display{image={last_im, im}, win=d, zoom=1}
	end
	--]]
end

camera:stop()
