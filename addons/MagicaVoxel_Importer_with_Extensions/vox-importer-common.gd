
const VoxFile = preload("./VoxFile.gd");
const VoxData = preload("./VoxFormat/VoxData.gd");
const VoxNode = preload("./VoxFormat/VoxNode.gd");
const VoxMaterial = preload("./VoxFormat/VoxMaterial.gd");
const VoxLayer = preload("./VoxFormat/VoxLayer.gd");
const CulledMeshGenerator = preload("./CulledMeshGenerator.gd");
const GreedyMeshGenerator = preload("./GreedyMeshGenerator.gd");

const debug_file = false;
const debug_models = false;

var fileKeyframeIds = [];

func import(source_path, destination_path, options, _platforms, _gen_files):
	var scale : float
	if options.PixelsPerMetr:
		scale = 1 / float(options.PixelsPerMetr)
	var greedy = true
	if options.has("GreedyMeshGenerator"):
		greedy = bool(options.GreedyMeshGenerator)
	var snaptoground = false
	if options.has("SnapToGround"):
		snaptoground = bool(options.SnapToGround)
	var shade_smooth = false
	if options.has("ShadeSmooth"):
		shade_smooth = bool(options.ShadeSmooth)
	var mergeKeyframes = false
	if options.has("FirstKeyframeOnly"):
		mergeKeyframes = not bool(options.FirstKeyframeOnly)


	var file = FileAccess.open(source_path, FileAccess.READ)

	if file == null:
		return FileAccess.get_open_error()

	var identifier = PackedByteArray([ file.get_8(), file.get_8(), file.get_8(), file.get_8() ]).get_string_from_ascii()
	var version = file.get_32()
	print('Importing: ', source_path,
				' (scale: ', scale,
				', file version: ', version,
				', greedy mesh: ', greedy,
				', snap to ground: ', snaptoground,
				', shade smooth: ', shade_smooth,
				', merge frames: ', mergeKeyframes,
				')');

	var vox = VoxData.new();
	if identifier == 'VOX ':
		var voxFile = VoxFile.new(file);
		while voxFile.has_data_to_read():
			read_chunk(vox, voxFile);
	file = null

	fileKeyframeIds.sort()

	var voxel_data = unify_voxels(vox, mergeKeyframes);
	var meshes = []
	for keyframeVoxels in voxel_data:
		if greedy:
			meshes.append(GreedyMeshGenerator.new().generate(vox, voxel_data[keyframeVoxels], scale, snaptoground, shade_smooth))
		else:
			meshes.append(CulledMeshGenerator.new().generate(vox, voxel_data[keyframeVoxels], scale, snaptoground))
	return meshes

func string_to_vector3(input: String) -> Vector3:
	var data = input.split_floats(' ');
	return Vector3(data[0], data[1], data[2]);

func byte_to_basis(data: int):
	var x_ind = ((data >> 0) & 0x03);
	var y_ind = ((data >> 2) & 0x03);
	var indexes = [0, 1, 2];
	indexes.erase(x_ind);
	indexes.erase(y_ind);
	var z_ind = indexes[0];
	var x_sign = 1 if ((data >> 4) & 0x01) == 0 else -1;
	var y_sign = 1 if ((data >> 5) & 0x01) == 0 else -1;
	var z_sign = 1 if ((data >> 6) & 0x01) == 0 else -1;
	var result = Basis();
	result.x[0] = x_sign if x_ind == 0 else 0;
	result.x[1] = x_sign if x_ind == 1 else 0;
	result.x[2] = x_sign if x_ind == 2 else 0;

	result.y[0] = y_sign if y_ind == 0 else 0;
	result.y[1] = y_sign if y_ind == 1 else 0;
	result.y[2] = y_sign if y_ind == 2 else 0;

	result.z[0] = z_sign if z_ind == 0 else 0;
	result.z[1] = z_sign if z_ind == 1 else 0;
	result.z[2] = z_sign if z_ind == 2 else 0;
	return result;

func read_chunk(vox: VoxData, file: VoxFile):
	var chunk_id = file.get_string(4);
	var chunk_size = file.get_32();
	var childChunks = file.get_32()

	file.set_chunk_size(chunk_size);
	match chunk_id:
		'SIZE':
			vox.current_index += 1;
			var model = vox.get_model();
			var x = file.get_32();
			var y = file.get_32();
			var z = file.get_32();
			model.size = Vector3(x, y, z);
			if debug_file: print('SIZE ', model.size);
		'XYZI':
			var model = vox.get_model();
			if debug_file: print('XYZI');
			for _i in range(file.get_32()):
				var x = file.get_8()
				var y = file.get_8()
				var z = file.get_8()
				var c = file.get_8()
				var voxel = Vector3(x, y, z)
				model.voxels[voxel] = c - 1
				if debug_file && debug_models: print('\t', voxel, ' ', c-1);
		'RGBA':
			vox.colors = []
			for _i in range(256):
				var r = float(file.get_8() / 255.0)
				var g = float(file.get_8() / 255.0)
				var b = float(file.get_8() / 255.0)
				var a = float(file.get_8() / 255.0)
				vox.colors.append(Color(r, g, b, a))
		'nTRN':
			var node_id = file.get_32();
			var attributes = file.get_vox_dict();
			var node = VoxNode.new(node_id, attributes);
			vox.nodes[node_id] = node;

			var child = file.get_32();
			node.child_nodes.append(child);

			file.get_32();
			node.layerId = file.get_32();
			var num_of_frames = file.get_32();

			if debug_file:
				print('nTRN[', node_id, '] -> ', child);
				if (!attributes.is_empty()): print('\t', attributes);
			if num_of_frames > 0:
				node.transforms = {};
			for _frame in range(num_of_frames):
				var keyframe = 0;
				var newTransform = { "position": Vector3(), "rotation": Basis() };
				var frame_attributes = file.get_vox_dict();
				if (frame_attributes.has('_f')):
					keyframe = int(frame_attributes['_f']);
				if (frame_attributes.has('_t')):
					var trans = frame_attributes['_t'];
					newTransform.position = string_to_vector3(trans);
					if debug_file: print('\tT: ', newTransform.position);
				if (frame_attributes.has('_r')):
					var rot = frame_attributes['_r'];
					newTransform.rotation = byte_to_basis(int(rot)).inverse();
					if debug_file: print('\tR: ', newTransform.rotation);
				node.transforms[keyframe] = newTransform;
				if not fileKeyframeIds.has(keyframe):
					fileKeyframeIds.append(keyframe);
		'nGRP':
			var node_id = file.get_32();
			var attributes = file.get_vox_dict();
			var node = VoxNode.new(node_id, attributes);
			vox.nodes[node_id] = node;

			var num_children = file.get_32();
			for _c in num_children:
				node.child_nodes.append(file.get_32());
			if debug_file:
				print('nGRP[', node_id, '] -> ', node.child_nodes);
				if (!attributes.is_empty()): print('\t', attributes);
		'nSHP':
			var node_id = file.get_32();
			var attributes = file.get_vox_dict();
			var node = VoxNode.new(node_id, attributes);
			vox.nodes[node_id] = node;

			var num_models = file.get_32();
			for _i in range(num_models):
				var keyframe = 0;
				var modelId = file.get_32();
				var model_attributes = file.get_vox_dict();
				if (model_attributes.has('_f')):
					keyframe = int(model_attributes['_f']);
				node.models[keyframe] = modelId;
				if not fileKeyframeIds.has(keyframe):
					fileKeyframeIds.append(keyframe);
			if debug_file:
				print('nSHP[', node_id,'] -> ', node.models);
				if (!attributes.is_empty()): print('\t', attributes);
		'MATL':
			var material_id = file.get_32() - 1;
			var properties = file.get_vox_dict();
			vox.materials[material_id] = VoxMaterial.new(properties);
			if debug_file:
				print("MATL ", material_id);
				print("\t", properties);
		'LAYR':
			var layer_id = file.get_32();
			var attributes = file.get_vox_dict();
			var isVisible = true;
			if '_hidden' in attributes and attributes['_hidden'] == '1':
				isVisible = false;
			var layer = VoxLayer.new(layer_id, isVisible);
			vox.layers[layer_id] = layer;
		_:
			if debug_file: print(chunk_id);
	file.read_remaining();

func unify_voxels(vox: VoxData, mergeKeyframes: bool):
	var node = vox.nodes[0];
	var layeredVoxelData = get_layeredVoxels(node, vox, -1, mergeKeyframes)
	return layeredVoxelData.getDataMergedFromLayers();

class LayeredVoxelData:
	var data_keyframed_layered = {};

	func combine(keyframeId, layerId, model):
		# Make sure there's space
		if not keyframeId in data_keyframed_layered:
			data_keyframed_layered[keyframeId] = {}
		if not layerId in data_keyframed_layered[keyframeId]:
			data_keyframed_layered[keyframeId][layerId] = {}
		# Add the model voxels to the data
		var offset = (model.size / 2.0).floor();
		for voxel in model.voxels:
			data_keyframed_layered[keyframeId][layerId][voxel - offset] = model.voxels[voxel];

	func combine_data(other):
		for keyframeId in other.data_keyframed_layered:
			if not keyframeId in data_keyframed_layered:
				data_keyframed_layered[keyframeId] = {}
			for layerId in other.data_keyframed_layered[keyframeId]:
				if not layerId in data_keyframed_layered[keyframeId]:
					data_keyframed_layered[keyframeId][layerId] = {}
				for voxel in other.data_keyframed_layered[keyframeId][layerId]:
					data_keyframed_layered[keyframeId][layerId][voxel] = (
						other.data_keyframed_layered[keyframeId][layerId][voxel]);

	func transform(transforms):
		var new_data = {};
		for keyframeId in data_keyframed_layered:
			new_data[keyframeId] = {}
			var transform = get_input_for_keyframe(keyframeId, transforms);
			for layerId in data_keyframed_layered[keyframeId]:
				new_data[keyframeId][layerId] = {}
				for voxel in data_keyframed_layered[keyframeId][layerId]:
					var half_step = Vector3(0.5, 0.5, 0.5);
					var new_voxel = (
						(transform.rotation * voxel+half_step-half_step).floor() +
						transform.position);
					new_data[keyframeId][layerId][new_voxel] = (
						data_keyframed_layered[keyframeId][layerId][voxel]);
		data_keyframed_layered = new_data;

	func getDataMergedFromLayers():
		# The result of this function
		var result = {};
		for keyframeId in data_keyframed_layered:
			result[keyframeId] = {}
			# Merge all layer data in layerId order (highest layer overrides all)
			var layerIds = data_keyframed_layered[keyframeId].keys();
			layerIds.sort();
			for layerId in layerIds:
				for voxel in data_keyframed_layered[keyframeId][layerId]:
					result[keyframeId][voxel] = data_keyframed_layered[keyframeId][layerId][voxel];
		# Return the merged data
		return result;

	static func get_input_for_keyframe(focusKeyframeId, inputCollection):
		var inputKeyframeIds = inputCollection.keys();
		inputKeyframeIds.sort();
		inputKeyframeIds.reverse();
		var result = inputKeyframeIds.back();
		for inputKeyframeId in inputKeyframeIds:
			if inputKeyframeId <= focusKeyframeId:
				result = inputKeyframeId;
				break;
		return inputCollection[result];


func get_layeredVoxels(node: VoxNode, vox: VoxData, layerId: int, mergeKeyframes: bool):
	var result = LayeredVoxelData.new();

	# Handle layers (keeping separated and ignoring hidden)
	if node.layerId in vox.layers:
		if vox.layers[node.layerId].isVisible:
			layerId = node.layerId;
		else:
			return result;

	# Add all models in this node
	if mergeKeyframes:
		for model_index in node.models:
			var modelId = node.models[model_index];
			var model = vox.models[modelId];
			result.combine(0, layerId, model);
	elif node.models.size() > 0:
		for fileKeyframeId in fileKeyframeIds:
			var frameModelId = LayeredVoxelData.get_input_for_keyframe(fileKeyframeId, node.models);
			var model = vox.models[frameModelId];
			result.combine(fileKeyframeId, layerId, model);

	# Process child nodes
	for child_index in node.child_nodes:
		var child = vox.nodes[child_index];
		var child_data = get_layeredVoxels(child, vox, layerId, mergeKeyframes);
		result.combine_data(child_data);

	# Run transforms
	result.transform(node.transforms);

	return result;
