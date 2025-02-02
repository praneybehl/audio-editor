
class @AudioEditor extends E.Component
	
	copy_of = (o)-> JSON.parse JSON.stringify o
	
	constructor: ->
		@state =
			tracks: [
				{
					id: "beat-track"
					type: "beat"
					muted: yes
					pinned: yes
				}
			]
			undos: []
			redos: []
			playing: no
			track_sources: []
			position: null
			position_time: null
			selection: null
			recording: no
			precording_enabled: no
	
	@document_version: 4
	@stuff_version: 3
	
	save: ->
		{document_id} = @props
		{tracks, selection, undos, redos} = @state
		doc = {
			version: AudioEditor.document_version
			state: {tracks, selection}
			undos, redos
		}
		localforage.setItem "document:#{document_id}", doc, (err)=>
			if err
				InfoBar.warn "Failed to save the document.\n#{err.message}"
				console.error err
			else
				render()
	
	load: ->
		{document_id} = @props
		localforage.getItem "document:#{document_id}", (err, doc)=>
			if err
				InfoBar.warn "Failed to load the document.\n#{err.message}"
				console.error err
			else if doc
				if not doc.version?
					InfoBar.warn "This document was created before document storage was even versioned. It cannot be loaded."
					return
				if doc.version > AudioEditor.document_version
					InfoBar.warn "This document was created with a later version of the editor. Reload to get the latest version."
					return
				if doc.version < AudioEditor.document_version
					
					# upgrading code goes here
					# for backwards compatible changes, the version number can simply be incremented
					
					upgrade = (fn)->
						fn doc.state
						fn state for state in doc.undos
						fn state for state in doc.redos
					
					if doc.version is 1
						doc.version++ # recordings added
					
					if doc.version is 2
						doc.version++ # pinned tracks mean the tracks aren't necessarily in order, so selections now use a list of track_ids
						upgrade (state)->
							if state.selection
								{track_a, track_b} = state.selection
								min_track_index = Math.min track_a, track_b
								max_track_index = Math.max track_a, track_b
								state.selection.track_ids = (track.id for track, track_index in state.tracks when min_track_index <= track_index <= max_track_index)
								delete state.selection.track_a
								delete state.selection.track_b
					
					if doc.version is 3
						doc.version++ # clip.time renamed to clip.position
						upgrade (state)->
							for track in state.tracks when track.type is "audio"
								for clip in track.clips
									clip.position = clip.time
									delete clip.time
					
					unless doc.version is AudioEditor.document_version
						InfoBar.warn "This document was created with an earlier version of the editor. There is no upgrade path as of yet, sorry."
						return
				
				{state, undos, redos} = doc
				{tracks, selection} = state
				@setState {tracks, undos, redos}
				@select Range.fromJSON selection if selection?
	
	undoable: (fn)->
		{tracks, selection, undos, redos} = @state
		tracks = copy_of tracks
		undos = copy_of undos
		redos = []
		undos.push
			tracks: copy_of tracks
			selection: copy_of selection
		fn tracks
		@setState {tracks, undos, redos}
	
	undo: ->
		{tracks, selection, undos, redos} = @state
		return unless undos.length
		tracks = copy_of tracks
		undos = copy_of undos
		redos = copy_of redos
		redos.push
			tracks: copy_of tracks
			selection: copy_of selection
		{tracks, selection} = undos.pop()
		@setState {tracks, undos, redos}
		@select Range.fromJSON selection if selection?
	
	redo: ->
		{tracks, selection, undos, redos} = @state
		return unless redos.length
		tracks = copy_of tracks
		undos = copy_of undos
		redos = copy_of redos
		undos.push
			tracks: copy_of tracks
			selection: copy_of selection
		{tracks, selection} = redos.pop()
		@setState {tracks, undos, redos}
		@select Range.fromJSON selection if selection?
	
	# @TODO: soft undo/redo
	
	get_max_length: ->
		{tracks} = @state
		
		max_length = 0
		for track in tracks when track.type is "audio"
			for clip in track.clips
				if clip.recording_id
					recording = AudioClip.recordings[clip.recording_id]
					if recording
						max_length = Math.max max_length, clip.position + (clip.length ? recording.length ? 0)
					else
						InfoBar.warn "Not all tracks have finished loading."
						return
				else
					audio_buffer = AudioClip.audio_buffers[clip.audio_id]
					if audio_buffer
						max_length = Math.max max_length, clip.position + clip.length
					else
						InfoBar.warn "Not all tracks have finished loading."
						return
		
		max_length
	
	get_current_position: ->
		@state.position +
			if @state.playing
				actx.currentTime - @state.position_time
			else
				0
	
	seek: (position, shiftKey)=>
		
		if isNaN position
			InfoBar.warn "Tried to seek to invalid position: #{position}"
			return
		
		position = Math.max 0, position
		max_length = @get_max_length()
		
		{playing, recording, selection} = @state
		
		return if recording
		
		if playing and max_length? and position < max_length
			@play_from position
			@setState {recording}
		else
			@pause()
			@setState
				position_time: actx.currentTime
				position: position
		
		if selection?
			if shiftKey
				@select new Range selection.a, position, selection.track_ids
			else if selection.length() is 0
				@select new Range position, position, selection.track_ids
	
	seek_to_start: (shiftKey)=>
		@seek 0, shiftKey
	
	seek_to_end: (shiftKey)=>
		end = @get_max_length()
		return unless end?
		@seek end, shiftKey
	
	play: =>
		@play_from @state.position ? 0
	
	play_from: (from_position)=>
		@pause() if @state.playing
		
		max_length = @get_max_length()
		return unless max_length?
		
		if from_position >= max_length or from_position < 0
			from_position = 0
		
		@setState
			tid: unless @state.recording then setTimeout @pause, (max_length - from_position) * 1000 + 20
			# NOTE: an extra few ms because it shouldn't fade out prematurely
			# (even though might sound better, it might lead you to believe
			# your audio doesn't need a brief fade out at the end when it does)
			
			position_time: actx.currentTime
			position: from_position
			
			playing: yes
			track_sources: @_start_playing from_position, actx
	
	_start_playing: (from_position, actx)->
		include_metronome = not (actx instanceof OfflineAudioContext)
		
		{tracks} = @state
		
		for track in tracks when track.type is "audio" and not track.muted
			for clip in track.clips
				loaded =
					if clip.recording_id
						AudioClip.recordings[clip.recording_id]?.chunks?
					else
						AudioClip.audio_buffers[clip.audio_id]?
				unless loaded
					InfoBar.warn "Not all tracks have finished loading."
					throw new Error "Not all tracks have finished loading."
				
		for track in tracks when not track.muted
			switch track.type
				when "beat"
					unless include_metronome
						# @TODO: metronome
						continue
				when "audio"
					for clip in track.clips
						source = actx.createBufferSource()
						source.gain = actx.createGain()
						
						if clip.recording_id
							recording = AudioClip.recordings[clip.recording_id]
							unless recording.audio_buffer?
								if recording.chunks[0]?.length
									recording.audio_buffer = actx.createBuffer recording.chunks.length, recording.chunks[0].length * recording.chunks[0][0].length, recording.sample_rate
									for channel, channel_index in recording.chunks
										for chunk, chunk_index in channel
											recording.audio_buffer.copyToChannel chunk, channel_index, chunk_index * chunk.length
							source.buffer = recording.audio_buffer
							clip_length = clip.length ? recording.length
						else
							source.buffer = AudioClip.audio_buffers[clip.audio_id]
							clip_length = clip.length
						
						source.connect source.gain
						source.gain.connect actx.destination
						
						start_time = actx.currentTime + Math.max(0, clip.position - from_position)
						starting_offset_into_clip = Math.max(0, from_position - clip.position) + clip.offset
						length_to_play_of_clip = clip_length - Math.max(0, from_position - clip.position)
						
						if length_to_play_of_clip > 0
							source.start start_time, starting_offset_into_clip, length_to_play_of_clip
							source
	
	pause: =>
		clearTimeout @state.tid
		for track_sources in @state.track_sources
			for source in track_sources
				source?.stop actx.currentTime + 1.0
				source?.gain.gain.value = 0
		@end_recording()
		@setState
			position_time: actx.currentTime
			position: @get_current_position()
			playing: no
			track_sources: []
	
	update_playback: =>
		if @state.playing
			@seek @get_current_position()
	
	end_recording: =>
		# method overridden by @record
		# (and then reset to an empty function when the recording is over)
	
	record: =>
		return if @state.recording
		# @TODO: use MediaDevices.getUserMedia when available
		navigator.getUserMedia audio: yes,
			(stream)=>
				recording_id = GUID()
				@undoable (tracks)=>
					{selection} = @state
					if selection?
						start_position = selection.start()
						sorted_audio_tracks = (track for track in @get_sorted_tracks tracks when track.type is "audio")
						track = selection.firstTrack(sorted_audio_tracks)
					if track?
						for clip in track.clips
							{clip_start, clip_end} = get_clip_start_end clip
							if clip_end > start_position
								track = null # track is no good, but keep the start position
					# @TODO: maybe make a helper that adds a track if there's no selection
					# and inserts a given clip
					if not track?
						start_position ?= 0
						track = {id: GUID(), type: "audio", clips: []}
						tracks.push track
						if start_position > 0
							@select new Range start_position, start_position, [track.id]
					
					clip =
						id: GUID()
						audio_id: recording_id
						recording_id: recording_id
						position: start_position
						offset: 0
					
					track.clips.push clip
					
					source = actx.createMediaStreamSource stream
					
					recording =
						id: recording_id
						chunks: [[], []]
						chunk_ids: [[], []]
						length: 0
					
					AudioClip.recordings[clip.recording_id] = recording
					AudioClip.loading[clip.audio_id] = yes
					
					current_chunk = 0
					chunk_size = 2 ** 14 # samples (2 to an integer power between 8 and 14 inclusive)
					
					final_recording_length = undefined
					
					recorder = actx.createScriptProcessor chunk_size, 2, if chrome? then 1 else 0
					recorder.onaudioprocess = (e)=>
						recording.sample_rate = e.inputBuffer.sampleRate
						
						chunks = []
						chunk_ids = []
						for i in [0...e.inputBuffer.numberOfChannels]
							# new Float32Array necessary in chrome
							data = new Float32Array e.inputBuffer.getChannelData i
							chunks.push recording.chunks[i].concat [data]
							chunk_ids.push recording.chunk_ids[i].concat [chunk_id = GUID()]
							do (chunk_id, data)=>
								localforage.setItem "recording:#{recording_id}:chunk:#{chunk_id}", data, (err)=>
									if err
										InfoBar.warn "Failing to store recording! #{err.message}"
										console.error "Failed to store recording chunk", err
						recording.chunks = chunks
						recording.chunk_ids = chunk_ids
						recording.length = final_recording_length ? chunk_ids[0].length * data.length / recording.sample_rate
						
						save = =>
							localforage.setItem "recording:#{clip.recording_id}", {
								id: recording.id
								sample_rate: recording.sample_rate
								chunk_ids: recording.chunk_ids
								length: recording.length
							}, (err)=>
								if err
									InfoBar.warn "Failing to store recording! #{err.message}"
									console.error "Failed to store recording metadata", err
						
						unless final_recording_length?
							@end_recording = =>
								final_recording_length = recording.length = @get_current_position() - start_position
								save()
								@setState
									recording: no
									position: start_position + final_recording_length
									position_time: actx.currentTime
								@end_recording = =>
						
						save()
						
						current_chunk += 1
						render()
						
						unless @state.recording?
							source.disconnect()
							recorder.disconnect()
							delete window["chrome bug workaround (#{recording_id})"]
					
					source.connect recorder
					recorder.connect actx.destination if chrome?
					# http://stackoverflow.com/questions/24338144/chrome-onaudioprocess-stops-getting-called-after-a-while
					if chrome? then window["chrome bug workaround (#{recording_id})"] = recorder
					
					@setState recording: yes, =>
						@play_from start_position
			
			(error)=>
				switch error.name
					when "PermissionDeniedError", "PermissionDismissedError"
						return
					when "NotFoundError"
						InfoBar.warn "No recording devices were found."
					when "SourceUnavailableError"
						InfoBar.warn "No available recording devices were found. Is one in use?"
					else
						InfoBar.warn "Failed to start recording: #{error.name}" + if error.message then ": #{error.message}"
				console.error "navigator.getUserMedia", error
	
	stop_recording: =>
		@pause()
	
	precord: (seconds_back_in_time_woo_time_travel)=>
		InfoBar.warn "Precording is not yet implemented"
	
	enable_precording: (seconds)=>
		InfoBar.warn "Sorry, precording is not yet implemented"
	
	select: (selection)=>
		@setState {selection}
	
	deselect: =>
		@select null
	
	select_all: =>
		{tracks} = @state
		max_length = @get_max_length()
		return unless max_length?
		@select new Range 0, max_length, (track.id for track in tracks)
	
	select_vertically: (direction, add)=>
		{tracks, selection} = @state
		return unless selection
		sorted_tracks = normal_tracks_in @get_sorted_tracks tracks
		switch direction
			when "up"
				selected_track_id = selection.firstTrackID(sorted_tracks)
				delta = -1
			when "down"
				selected_track_id = selection.lastTrackID(sorted_tracks)
				delta = +1
		for track, track_index in sorted_tracks
			break if track.id is selected_track_id
		next_selected_track_id = sorted_tracks[track_index + delta]?.id
		if add
			@select new Range selection.a, selection.b, selection.track_ids.concat(next_selected_track_id) if next_selected_track_id
		else
			@select new Range selection.a, selection.b, [next_selected_track_id ? selected_track_id]
	
	select_horizontally: (seconds)->
		{selection} = @state
		max_length = @get_max_length()
		return unless max_length?
		to = Math.max(0, Math.min(max_length, selection.b + seconds))
		@select new Range selection.a, to, selection.track_ids
	
	select_up: (add)=>
		@select_vertically "up", add
	
	select_down: (add)=>
		@select_vertically "down", add
	
	delete: =>
		{selection} = @state
		return unless selection?.length()
		
		@undoable (tracks)=>
			collapsed = selection.collapse tracks
			@select collapsed
			@seek collapsed.start()
	
	copy: =>
		{selection, tracks} = @state
		return unless selection?.length()
		sorted_tracks = @get_sorted_tracks tracks
		localforage.setItem "clipboard", selection.contents(sorted_tracks), (err)=>
			if err
				InfoBar.warn "Failed to store clipboard data.\n#{err.message}"
				console.error err
	
	cut: =>
		@copy()
		@delete()
	
	paste: =>
		localforage.getItem "clipboard", (err, clipboard)=>
			if err
				InfoBar.warn "Failed to load clipboard data.\n#{err.message}"
				console.error err
			else if clipboard?
				
				if not clipboard.version?
					InfoBar.warn "The clipboard data was copied before clipboard data was versioned. It cannot be pasted."
					return
				if clipboard.version > AudioEditor.stuff_version
					InfoBar.warn "The clipboard data was copied from a later version of the editor. Reload to get the latest version."
					return
				if clipboard.version < AudioEditor.stuff_version
					# upgrading code should go here
					# for backwards compatible changes, the version number can simply be incremented
					
					if clipboard.version is 1
						clipboard.version += 1 # recordings added
					
					if clipboard.version is 2
						clipboard.version += 1 # renamed clip.time to clip.position
						for row in clipboard.rows
							for clip in row
								clip.position = clip.time
								delete clip.time
					
					unless clipboard.version is AudioEditor.stuff_version
						InfoBar.warn "The clipboard data was copied from an earlier version of the editor. There is no upgrade path as of yet, sorry."
						return
				
				@undoable (tracks)=>
					{selection} = @state
					sorted_tracks = @get_sorted_tracks tracks
					
					if selection?
						# @TODO: handle excess selected tracks better
						# (currently it collapses the entire selection, but only inserts as many rows as are in the clipboard)
						collapsed_selection = selection.collapse tracks
						track_id = collapsed_selection.firstTrackID(sorted_tracks)
						position = collapsed_selection.start()
					else
						track_id = null
						position = 0
					after = Range.insert clipboard, position, track_id, tracks, sorted_tracks
					@select after
	
	insert: (stuff, position, track_id)->
		@undoable (tracks)=>
			sorted_tracks = @get_sorted_tracks tracks
			Range.insert stuff, position, track_id, tracks, sorted_tracks
	
	set_track_prop: (track_id, prop, value)->
		@undoable (tracks)=>
			for track in tracks when track.id is track_id
				track[prop] = value
	
	mute_track: (track_id)=>
		@set_track_prop track_id, "muted", on
	
	unmute_track: (track_id)=>
		@set_track_prop track_id, "muted", off
	
	pin_track: (track_id)=>
		@set_track_prop track_id, "pinned", on
	
	unpin_track: (track_id)=>
		@set_track_prop track_id, "pinned", off
	
	remove_track: (track_id)=>
		@undoable (tracks)=>
			{selection} = @state
			for track, track_index in tracks when track.id is track_id by -1
				tracks.splice track_index, 1
				if selection?.containsTrack track
					updated_selection = new Range selection.a, selection.b, (track_id for track_id in selection.tracks when track_id isnt track.id)
					if updated_selection.length
						@select updated_selection
					else
						@deselect()
	
	add_clip: (file, at_selection)->
		{document_id} = @props
		if at_selection
			{selection} = @state
			return unless selection?
		reader = new FileReader
		reader.onload = (e)=>
			array_buffer = e.target.result
			clip = {id: GUID(), audio_id: GUID(), position: 0, offset: 0}
			
			AudioClip.loading[clip.audio_id] = yes
			
			localforage.setItem "audio:#{clip.audio_id}", array_buffer, (err)=>
				if err
					InfoBar.warn "Failed to store audio data.\n#{err.message}"
					console.error err
				else
					# @TODO: optimize by decoding and storing in parallel, but keep good error handling
					actx.decodeAudioData array_buffer, (buffer)=>
						AudioClip.audio_buffers[clip.audio_id] = buffer
						
						clip.length = buffer.length / buffer.sampleRate
						
						stuff = {version: AudioEditor.stuff_version, rows: [[clip]], length: clip.length}
						if at_selection
							@insert stuff, selection.start(), selection.firstTrackID()
						else
							@insert stuff, 0
			, (e)=>
				InfoBar.warn "Audio not playable or not supported."
				console.error e
		
		reader.onerror = (e)=>
			InfoBar.warn "Failed to read audio file."
			console.error e
		
		reader.readAsArrayBuffer file
	
	get_sorted_tracks: (tracks)=>
		track_els = React.findDOMNode(@).querySelectorAll ".track"
		track_positions = (track_el.getBoundingClientRect().top for track_el in track_els)
		track_positions = {}
		for track_el in track_els
			track_positions[track_el.dataset.trackId] = track_el.getBoundingClientRect().top
		tracks.slice().sort (track_a, track_b)->
			track_positions[track_a.id] - track_positions[track_b.id]
	
	export_as: (file_type, range)=>
		sample_rate = 44100
		if range?
			start = range.start()
			length = range.length()
		else
			start = 0
			length = @get_max_length()
		number_of_channels = 2
		oactx = new OfflineAudioContext number_of_channels, sample_rate * length, sample_rate
		@_start_playing start, oactx
		oactx.startRendering()
			.then (rendered_audio_buffer)=>
				export_audio_buffer_as rendered_audio_buffer, file_type
	
	componentWillUpdate: (next_props, next_state)=>
		# for transitioning track positions
		@last_track_rects = null
		# @TODO: transition removing/unremoving tracks
		if @state.tracks.length is next_state.tracks.length
			for track_current, track_index in @state.tracks
				track_future = next_state.tracks[track_index]
				if track_future.pinned isnt track_current.pinned
					track_els = React.findDOMNode(@).querySelectorAll(".track")
					@last_track_rects = (track_el.getBoundingClientRect() for track_el in track_els)
	
	componentDidUpdate: (last_props, last_state)=>
		{document_id} = @props
		{tracks, selection, undos, redos} = @state
		
		if (
			tracks isnt last_state.tracks or
			selection isnt last_state.selection or
			undos isnt last_state.undos or
			redos isnt last_state.redos
		)
			@save()
		
		if tracks isnt last_state.tracks
			@update_playback()
			AudioClip.load_clips tracks
			
		# transition track positions
		transition_seconds = 0.5
		if @last_track_rects
			track_els = React.findDOMNode(@).querySelectorAll(".track")
			for track_el, track_index in track_els
				current_rect = track_el.getBoundingClientRect()
				last_rect = @last_track_rects[track_index]
				track_el.style.transform = "translateY(#{last_rect.top - current_rect.top}px)"
				do (track_el)->
					setTimeout ->
						track_el.style.transition = "transform #{transition_seconds}s ease"
						setTimeout ->
							track_el.style.transform = "translateY(0)"
							setTimeout ->
								track_el.style.transition = ""
							, transition_seconds * 1000
	
	componentDidMount: =>
		
		@load()
		
		window.addEventListener "keydown", @keydown_listener = (e)=>
			return if e.defaultPrevented
			return if e.altKey
			
			if e.ctrlKey
				switch e.keyCode
					when 65 # A
						@select_all() unless e.shiftKey
					when 83 # S
						if e.shiftKey then @TODO.save_as() else @TODO.save()
					when 79 # O
						@TODO.open() unless e.shiftKey
					when 78 # N
						@TODO.new() unless e.shiftKey
					when 88 # X
						@cut() unless e.shiftKey
					when 67 # C
						@copy() unless e.shiftKey
					when 86 # V
						@paste() unless e.shiftKey
					when 90 # Z
						if e.shiftKey then @redo() else @undo()
					when 89 # Y
						@redo() unless e.shiftKey
					else
						return # don't prevent default
			else
				switch e.keyCode
					# @TODO: media keys?
					when 32 # Spacebar
						unless e.target.tagName.match /button/i
							if @state.playing
								@pause()
							else
								@play()
					when 46, 8 # Delete, Backspace
						@delete()
					when 82 # R
						if @state.recording
							@stop_recording()
						else
							@record()
					# @TODO: finer control
					when 37 # Left
						if e.shiftKey
							@select_horizontally -1
						else
							@seek @get_current_position() - 1
					when 39 # Right
						if e.shiftKey
							@select_horizontally +1
						else
							@seek @get_current_position() + 1
					when 38, 33 # Up, Page Up
						@select_up e.shiftKey
					when 40, 34 # Down, Page Down
						@select_down e.shiftKey
					when 36 # Home
						@seek_to_start e.shiftKey
					when 35 # End
						@seek_to_end e.shiftKey
					else
						return # don't prevent default
			
			e.preventDefault()
	
	componentWillUnmount: ->
		@pause()
		window.removeEventListener "keydown", @keydown_listener
	
	render: ->
		{tracks, selection, position, position_time, playing, recording, precording_enabled} = @state
		{themes, set_theme} = @props
		E ".audio-editor",
			className: {playing}
			tabIndex: 0
			role: "application"
			style: outline: "none"
			onMouseDown: (e)=>
				return if e.isDefaultPrevented()
				unless e.button > 0
					e.preventDefault()
				React.findDOMNode(@).focus()
			onDragOver: (e)=>
				return if e.isDefaultPrevented()
				e.preventDefault()
				e.dataTransfer.dropEffect = "copy"
				@deselect()
			onDrop: (e)=>
				return if e.isDefaultPrevented()
				e.preventDefault()
				for file in e.dataTransfer.files
					@add_clip file
			E Controls, {playing, recording, selection, precording_enabled, themes, set_theme, editor: @, key: "controls"}
			E "div",
				key: "infobar"
				E InfoBar #, ref: (@infobar)=> # @TODO: instanced InfoBar API
			E TracksArea, {tracks, selection, position, position_time, playing, editor: @, key: "tracks-area"}
