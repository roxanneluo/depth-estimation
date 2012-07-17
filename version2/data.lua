require 'torch'
require 'paths'
require 'xlua'
require 'common'
require 'image'
require 'sfm2'
require 'opencv24'
require 'groundtruth'

function new_dataset(path, calibrationp, datap, groundtruthp)
   if path:sub(-1) ~= '/' then path = path .. '/' end
   local dataset = {}
   dataset.path = path
   dataset.calibrationp = calibrationp
   dataset.datap = datap
   dataset.groundtruthp = groundtruthp
   local names = ls2(dataset.path .. 'images/',
		     function(a) return tonumber(a:sub(1,-5)) ~= nil end)

   dataset.image_names_idx = {}
   dataset.image_idx_names = {}
   for i = 2,#names do
      dataset.image_names_idx[names[i]] = i-1
      dataset.image_idx_names[i-1] = names[i]
   end
   function dataset:get_idx_from_name(name)
      return self.image_names_idx[name]
   end
   function dataset:get_name_by_idx(idx)
      return self.image_idx_names[idx]
   end
   function dataset:get_image_names()
      return self.image_idx_names
   end
   
   dataset.images = {}
   function dataset:get_image_by_name(name)
      if not dataset.images[name] then
	 local img
	 if paths.filep(string.format("%simages/%s", self.path, name)) then
	    img = image.load(string.format("%simages/%s", self.path, name))
	 else
	    error(string.format("Image %simages/%s does not exist.", self.path, name))
	 end
	 img = image.scale(img, self.calibrationp.wImg, self.calibrationp.hImg)
	 img = sfm2.undistortImage(img, self.calibrationp.K, self.calibrationp.distortion)
	 img = image.scale(img, self.datap.wImg, self.datap.hImg)
	 dataset.images[name] = img
      end
      return dataset.images[name]
   end
   function dataset:get_image_by_idx(idx)
      return self:get_image_by_name(self:get_name_by_idx(idx))
   end

   dataset.prev_images = {}
   dataset.masks = {}
   function dataset:get_prev_image_by_name(name)
      if not self.prev_images[name] then
	 local img1 = self:get_image_by_idx(self:get_idx_from_name(name)-1)
	 local img2 = self:get_image_by_name(name)
	 if self.calibrationp.rectify then
	    error('Rectification not implemented')
	 end
	 self.masks[name] = torch.Tensor(img1:size(2), img1:size(2)):fill(1)
	 self.prev_images[name] = img1
      end
      return self.prev_images[name]
   end
   function dataset:get_prev_image_by_idx(idx)
      return self:get_prev_image_by_name(self:get_name_by_idx(idx))
   end

   function dataset:get_mask_by_name(name)
      if not self.masks[name] then
	 self:get_prev_image_by_name(name)
      end
      return self.masks[name]
   end
   function dataset:get_mask_by_idx(idx)
      return self:get_mask_by_name(self:get_name_by_idx(idx))
   end

   dataset.gt = {}
   function dataset:get_gt_by_name(name)
      if not dataset.gt[name] then
	 local gtdir = self.path .. "rectified_flow4/"
	 gtdir = gtdir .. self.datap.wImg .. 'x' .. self.datap.hImg .. '/'
	 if self.groundtruthp.type == 'cross-correlation' then
	    gtdir = gtdir .. self.groundtruthp.params.wWin .. 'x'
	    gtdir = gtdir .. self.groundtruthp.params.hWin .. 'x'
	    gtdir = gtdir .. self.groundtruthp.params.wKernel .. 'x'
	    gtdir = gtdir .. self.groundtruthp.params.hKernel .. '/'
	    gtdir = gtdir .. 'max/'
	 elseif self.groundtruthp.type == 'liu' then
	    gtdir = gtdir .. 'celiu/'
	 else
	    error('Groundtruth '..self.groundtruthp.type..' not supported.')
	 end
	 local name2 = name
	 if (name2:sub(-4) == '.jpg') or (name2:sub(-4) == '.png') then
	    name2 = name2:sub(1,-5)
	 end
	 local gtpath = string.format("%s%s.flow", gtdir, name2)
	 
	 if not paths.filep(gtpath) then
	    local im1 = self:get_prev_image_by_name(name)
	    local im2 = self:get_image_by_name(name)
	    local mask = self:get_mask_by_name(name)
	    local flow, conf = generate_groundtruth(self.groundtruthp, im1, im2, mask)
	    torch.save(gtpath, {flow, conf})
	 end
	 local flowraw = torch.load(gtpath)
	 local flow = flowraw[1]
	 local conf = flowraw[2]
	 return flow, conf
      end
      return dataset.gt[name]
   end
   function dataset:get_gt_by_idx(idx)
      return self:get_gt_by_name(self:get_name_by_idx(idx))
   end

   return dataset
end

function generate_groundtruth(groundtruthp, im1, im2, mask)
   --print('Computing '..groundtruthp.type..' groundtruth '..filepath)
   local flow, conf
   if groundtruthp.type == 'cross-correlation' then
      flow, conf = compute_groundtruth_cross_correlation(groundtruthp, im1, im2, mask)
   elseif groundtruthp.type == 'liu' then
      flow, conf = compute_groundtruth_liu(groundtruthp, im1, im2)
   else
      error("Can't compute groundtruth of type "..groundtruthp.type)
   end
   return flow, conf
end

--[[
function generate_training_patches(raw_data, networkp, learningp)
   local patches = {}
   patches.images = raw_data.polar_images
   patches.prev_images = raw_data.polar_prev_images
   patches.patches = {}
   patches.flow = {}
   function patches:getPatch(i)
      return {self.prev_images[self.patches[i][1] ]:sub(1, 3,
						       self.patches[i][2],self.patches[i][3]-1,
						       self.patches[i][4],self.patches[i][5]-1),
	      self.images[self.patches[i][1] ]:sub(1, 3,
						  self.patches[i][2], self.patches[i][3]-1,
						  self.patches[i][4], self.patches[i][5]-1)}
   end
   function patches:size()
      return #self.patches
   end
   local wPatch = networkp.wKernel
   local hPatch = networkp.hKernel + networkp.hWin - 1
   local wOffset = 0
   local hOffset = math.ceil(networkp.hKernel/2)-1
   local i = 1
   while i <= learningp.n_train_set do
      local iImg = randInt(1, #raw_data.polar_images + 1)
      local x = randInt(1, networkp.wInput - wPatch)
      local y = randInt(1, networkp.hInput - hPatch)
      local mask_patch = raw_data.polar_prev_images_masks[iImg]:sub(y, y+hPatch-1,
								    x, x+wPatch-1)
      local gt_mask_center = raw_data.polar_groundtruth_masks[iImg][y+hOffset][x+wOffset]

      if (mask_patch:lt(0.1):sum() == 0) and (gt_mask_center > 0.9) then
	 patches.patches[i] = {iImg, y, y+hPatch, x, x+wPatch}
	 patches.flow[i] = raw_data.polar_groundtruth[iImg][y+hOffset][x+wOffset]
	 i = i + 1
      end
   end
   return patches
end
--]]