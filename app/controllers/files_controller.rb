#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class FilesController < ApplicationController
  before_filter :require_context, :except => [:public_feed,:full_index,:assessment_question_show, :image_thumbnail]
  before_filter :check_file_access_flags, :only => :show_relative

  before_filter { |c| c.active_tab = "files" }

  def quota
    get_quota
    if authorized_action(@context.attachments.new, @current_user, :create)
      h = ActionView::Base.new
      h.extend ActionView::Helpers::NumberHelper
      result = {
        :quota => h.number_to_human_size(@quota),
        :quota_used => h.number_to_human_size(@quota_used),
        :quota_full => (@quota_used >= @quota)
      }
      render :json => result.to_json
    end
  end
  
  def check_file_access_flags
    if params[:user_id] && params[:ts] && params[:verifier]
      user = User.find_by_id(params[:user_id])
      if user && user.valid_access_verifier?(params[:ts], params[:verifier])
        # attachment.rb checks for this session attribute when determining 
        # permissions, but it should be ignored by the rest of the models' 
        # permission checks
        session['file_access_user_id'] = user.id
        session['file_access_expiration'] = 1.hour.from_now.to_i
      end
    end
    # These sessions won't get deleted when the user logs out since this
    # is on a separate domain, so we've added our own (stricter) timeout.
    if session && session['file_access_user_id'] && session['file_access_expiration'].to_i > Time.now.to_i
      session['file_access_expiration'] = 1.hour.from_now.to_i
    end
    true
  end
  protected :check_file_access_flags
  
  def retrieve_folders
    Folder.root_folders(@context)
    @all_folders = @context.active_folders_detailed.to_a
    @folders = @all_folders.select {|f| f.grants_rights?(@current_user, session, :read)[:read] }
    @root_folders = @all_folders.select {|f| f.parent_folder_id == nil}
    @current_folder ||= @root_folders[0]
  end
  protected :retrieve_folders
  
  def index
    return full_index if !params[:old_style] && request.format != :json
    add_crumb("Files", named_context_url(@context, :context_files_url))
    if authorized_action(@context.attachments.new, @current_user, :read)
      @current_folder = Folder.find_folder(@context, params[:folder_id])
      get_quota
      retrieve_folders if !request.xhr? || !@current_folder
      if !@current_folder || authorized_action(@current_folder, @current_user, :read)
        @current_sub_folders = @current_folder.active_sub_folders
        if @context.grants_right?(@current_user, session, :manage_files)
          @current_attachments = @current_folder.active_file_attachments
        else
          @current_attachments = @current_folder.visible_file_attachments
          @root_folders = @root_folders.select{|f| f.visible? } rescue []
          @folders = @folders.select{|f| f.visible? } rescue []
          @current_folder = @root_folders[0] if !@current_folder.visible?
        end
        @current_attachments = @current_attachments.scoped(:include => [:thumbnail, :media_object])
        log_asset_access("files:#{@context.asset_string}", "files", 'other')
        respond_to do |format|
          format.html
          format.xml  { render :xml => @current_attachments.to_xml }
          if params[:folder_id]
            format.json { render :json => @current_attachments.to_json(:methods => [:readable_size, :currently_locked], :permissions => {:user => @current_user, :session => session}) }
          else
            format.json { render :json => @context.file_structure_for(@current_user).to_json(:permissions => {:user => @current_user}, :methods => [:readable_size, :mime_class, :currently_locked, :collaborator_ids]) }
           end
        end
      end
    end
  end
  
  def list
    if authorized_action(@context, @current_user, :read)
      can_manage_files = @context.grants_right?(@current_user, session, :manage_files)
      json = Rails.cache.fetch(['file_list_json', @context.cache_key, (@current_user.cache_key rescue 'nobody')].cache_key) do
        @visible_folders = @context.active_folders_detailed.select{|f| f.grants_right?(@current_user, session, :read_contents)}
        @files = @context.active_attachments.scoped(:include => [:thumbnail, :media_object])
        visible_folders_hash = {}
        @visible_folders.each{|f| visible_folders_hash[f.id] = true }
        @visible_files = @files.select{|a| can_manage_files || (!a.currently_locked && visible_folders_hash[a.folder_id]) }
        (@visible_folders + @visible_files).to_json
      end
      render :json => json
    end
  end

  def full_index
    get_context
    get_quota
    add_crumb("Files", named_context_url(@context, :context_files_url))
    @contexts = [@context]
    if !@context.is_a?(User) || (@context == @current_user && params[:show_all_contexts])
      get_all_pertinent_contexts
    end
    @too_many_contexts = @contexts.length > 15
    @contexts = @contexts[0,15]
    if @contexts.length <= 1 && !authorized_action(@context.attachments.new, @current_user, :read)
      return
    end
    return unless tab_enabled?(@context.class::TAB_FILES)
    @file_structures = []
    @contexts.each do |context|
      Folder.root_folders(context)
      context.users rescue nil
      @file_structures << [context, context.file_structure_for(@current_user)]
    end
    @context = UserProfile.new(@context) if @context == @current_user
    respond_to do |format|
      if @contexts.empty? #authorized_action(@context, @current_user, :read)
        format.html { redirect_to !@context || @context == @current_user ? dashboard_url : named_context_url(@context, :context_url) }
      else
        format.html { render :action => 'full_index' }
      end
      format.xml  { render :xml => @file_structures.to_xml }
      format.json { render :json => @file_structures.to_json }
    end
  end
  
  def text_show
    @attachment = @context.attachments.find(params[:file_id])
    if authorized_action(@attachment,@current_user,:read)
      if @attachment.grants_right?(@current_user, nil, :download)
        @headers = false
        @tag = @attachment.context_module_tag
        @module = @attachment.context_module_tag.context_module rescue nil
        render
      else
        show
      end
    end
  end
  
  def assessment_question_show
    @context = AssessmentQuestion.find(params[:assessment_question_id])
    @attachment = @context.attachments.find(params[:id])
    @skip_crumb = true
    if @attachment.deleted?
      flash[:notice] = "The file #{@attachment.display_name} has been deleted"
      redirect_to dashboard_url
    end
    show
  end
  
  def show
    params[:id] ||= params[:file_id]
    @attachment = @context.attachments.find(params[:id])
    params[:download] ||= params[:preview]
    @context = UserProfile.new(@context) if @context == @current_user
    add_crumb("Files", named_context_url(@context, :context_files_url)) unless @skip_crumb
    if @attachment.deleted?
      flash[:notice] = "The file #{@attachment.display_name} has been deleted"
      if params[:preview] && @attachment.mime_class == 'image'
        redirect_to '/images/blank.png'
      elsif request.format == :json
        render :json => {:deleted => true}.to_json
      else
        redirect_to named_context_url(@context, :context_files_url)
      end
      return
    end

    if (params[:download] && params[:verifier] && params[:verifier] == @attachment.uuid) || authorized_action(@attachment, @current_user, :read)
      if params[:download]
        if (params[:verifier] && params[:verifier] == @attachment.uuid) || (@attachment.grants_right?(@current_user, session, :download))
          disable_page_views if params[:preview]
          @attachment.context_module_action(@current_user, :read) unless params[:preview]
          log_asset_access(@attachment, "files", "files") unless params[:preview]
          begin
            send_s3_file(@attachment)
          rescue => e
            @not_found_message = "It looks like something went wrong when this file was uploaded, and we can't find the actual file.  You may want to notify the owner of the file and have them re-upload it."
            logger.error "Error downloading a file: #{e} - #{e.backtrace}"
            render :template => 'shared/errors/404_message', :status => :bad_request
          end
          return
        elsif authorized_action(@attachment, @current_user, :read)
          respond_to do |format|
            if params[:preview] && @attachment.mime_class == 'image'
              format.html { redirect_to '/images/lock.png' }
            else
              format.html { render :action => 'show' }
            end
            @attachment.scribd_doc = nil unless @attachment.grants_right?(@current_user, session, :download)
            format.xml  { render :xml => @attachment.to_xml }
            format.json { render :json => @attachment.to_json(:permissions => {:user => @current_user}) }
          end
        end
      elsif params[:inline]
        generate_new_page_view
        log_asset_access(@attachment, 'files', 'files')
        render :json => {:ok => true}.to_json
      else
        respond_to do |format|
          if params[:preview] && @attachment.mime_class == 'image'
            format.html { redirect_to '/images/lock.png' }
          else
            if @files_domain
              @headers = false
              @show_left_side = false
            end
            format.html # show.rhtml
          end
          @attachment.scribd_doc = nil unless @attachment.grants_right?(@current_user, session, :download)
          format.xml  { render :xml => @attachment.to_xml }
          format.json { render :json => @attachment.to_json(:permissions => {:user => @current_user}) }
        end
      end
    end
  end

  def show_relative
    path = params[:file_path]

    #if the relative path matches the given file id use that file
    if @attachment = @context.attachments.find_by_id(params[:file_id])
      if @attachment.matches_full_display_path?(path) || @attachment.matches_full_path?(path)
        params[:id] = params[:file_id]
      else
        @attachment = nil
      end
    end

    if !@attachment
      #The relative path is for a different file, try to find it
      @attachments = @context.attachments.active.to_a
      @attachment  = @attachments.find { |a| a.matches_full_display_path?(path) }
      @attachment  ||= @attachments.find { |a| a.matches_full_path?(path) }
      Attachment.find(0) if !@attachment
      params[:id] = @attachment ? @attachment.id : nil
    end

    params[:download] = '1'
    show
  end
  
  # checks if for the current root account there's a 'files' domain
  # defined and tried to use that.  This way any files that we stream through
  # a canvas URL are at least on a separate subdomain and the javascript 
  # won't be able to access or update data with AJAX requests.
  def safer_domain_available?
    if !@files_domain && request.host_with_port != HostUrl.file_host(@domain_root_account)
      @safer_domain_host = HostUrl.file_host(@domain_root_account)
    end
    !!@safer_domain_host
  end
  protected :safer_domain_available?
  
  def attachment_content
    @attachment = @context.attachments.active.find(params[:file_id])
    if authorized_action(@attachment, @current_user, :update)
      # The files page lets you edit text content inline by firing off a json
      # request to get the data.
      if Attachment.local_storage?
        @headers = false if @files_domain
        str = File.read(@attachment.full_filename)
        render :json => {:body => str}.to_json
      else
        require 'aws/s3'
        str = ""
        io = StringIO.new
        AWS::S3::S3Object.stream(@attachment.full_filename, @attachment.bucket_name) do |chunk|
          io.write chunk
        end
        io.close_write
        io.rewind
        str = io.read
        render :json => {:body => str}.to_json
      end
     end
  end
  
  def send_s3_file(attachment)
    if params[:inline] && attachment.content_type && (attachment.content_type.match(/\Atext/) || attachment.mime_class == 'text' || attachment.mime_class == 'html' || attachment.mime_class == 'code')
      if safer_domain_available?
        redirect_to safe_domain_file_url(attachment, @safer_domain_host)
      elsif Attachment.local_storage?
        @headers = false if @files_domain
        send_file(attachment.full_filename, :type => attachment.content_type, :disposition => 'inline')
      else
        require 'aws/s3'
        send_file_headers!( :length=>AWS::S3::S3Object.about(attachment.full_filename, attachment.bucket_name)["content-length"], :filename=>attachment.filename, :disposition => 'inline', :type => attachment.content_type)
        render :status => 200, :text => Proc.new { |response, output|
          AWS::S3::S3Object.stream(attachment.full_filename, attachment.bucket_name) do |chunk|
           output.write chunk
          end
        }
      end
    elsif attachment.inline_content? && !@context.is_a?(AssessmentQuestion)
      if params[:file_path] || !params[:wrap]
        if safer_domain_available?
          redirect_to safe_domain_file_url(attachment, @safer_domain_host)
        elsif Attachment.local_storage?
          @headers = false if @files_domain
          send_file(attachment.full_filename, :type => attachment.content_type, :disposition => 'inline')
        else
          require 'aws/s3'
          send_file_headers!( :length=>AWS::S3::S3Object.about(attachment.full_filename, attachment.bucket_name)["content-length"], :filename=>attachment.filename, :disposition => 'inline', :type => attachment.content_type)
          render :status => 200, :text => Proc.new { |response, output|
            AWS::S3::S3Object.stream(attachment.full_filename, attachment.bucket_name) do |chunk|
             output.write chunk
            end
          }
        end
      else
        # If the file is inlineable then redirect to the 'show' action 
        # so we can wrap it in all the Canvas header/footer stuff
        redirect_to(named_context_url(@context, :context_file_url, attachment.id))
      end
    else
      if safer_domain_available?
        redirect_to safe_domain_file_url(attachment, @safer_domain_host)
      elsif Attachment.local_storage?
        @headers = false if @files_domain
        send_file(attachment.full_filename, :type => attachment.content_type, :disposition => 'attachment')
      else
        redirect_to attachment.cacheable_s3_url
      end
    end
  end
  protected :send_s3_file
  
  # GET /files/new
  def new
    @attachment = @context.attachments.build
    if authorized_action(@attachment, @current_user, :create)
    end
  end

  # POST /files
  # POST /files.xml
  def create
    @folder = @context.folders.active.find_by_id(params[:attachment].delete(:folder_id))
    @folder ||= Folder.unfiled_folder(@context)
    params[:attachment][:uploaded_data] ||= params[:attachment_uploaded_data]
    params[:attachment][:user] = @current_user
    params[:attachment].delete :context_id
    params[:attachment].delete :context_type
    @attachment = @context.attachments.new #(params[:attachment])
    if authorized_action(@attachment, @current_user, :create)
      get_quota
      return if quota_exceeded(named_context_url(@context, :context_files_url))
      respond_to do |format|
        @attachment.folder_id = @folder.id
        success = nil
        if params[:attachment] && params[:attachment][:source_attachment_id]
          a = Attachment.find(params[:attachment].delete(:source_attachment_id))
          if a.root_attachment_id && att = @folder.attachments.find_by_id(a.root_attachment_id)
            @attachment = att
            success = true
          elsif a.grants_right?(@current_user, session, :download)
            @attachment = a.clone_for(@context, @attachment)
            success = @attachment.save
          end
        end
        success = @attachment.update_attributes(params[:attachment]) if params[:attachment][:uploaded_data]
        unless (@attachment.cacheable_s3_url rescue nil)
          success = false
          if (params[:attachment][:uploaded_data].size == 0 rescue false)
            @attachment.errors.add_to_base("That file is empty.  Please upload a different file.")
          else
            @attachment.errors.add_to_base("Upload failed, please try again.")
          end
          unless @attachment.new_record?
            @attachment.destroy rescue @attachment.delete
          end
        end
        if success
          @attachment.move_to_bottom
          flash[:notice] = 'File was successfully uploaded.'
          format.html { return_to(params[:return_to], named_context_url(@context, :context_files_url)) }
          format.xml  { head :created, :location => named_context_url(@context, :context_files_url) }
          format.json { render_for_text @attachment.to_json(:allow => :uuid, :methods => [:uuid,:readable_size,:mime_class,:currently_locked,:scribdable?], :permissions => {:user => @current_user, :session => session}) }
          format.text { render_for_text @attachment.to_json(:allow => :uuid, :methods => [:uuid,:readable_size,:mime_class,:currently_locked,:scribdable?], :permissions => {:user => @current_user, :session => session}) }
        else
          format.html { render :action => "new" }
          format.xml  { render :xml => @attachment.errors.to_xml }
          format.json { render :json => @attachment.errors.to_json }
          format.text { render :json => @attachment.errors.to_json }
        end
      end
    end
  end

  def update
    @attachment = @context.attachments.find(params[:id])
    @folder = @context.folders.active.find(params[:attachment][:folder_id]) rescue nil
    @folder ||= @attachment.folder
    @folder ||= Folder.unfiled_folder(@context)
    if authorized_action(@attachment, @current_user, :update)
      respond_to do |format|
        just_hide = params[:attachment][:just_hide]
        hidden = params[:attachment][:hidden]
        params[:attachment].delete_if{|k, v| ![:display_name, :locked, :lock_at, :unlock_at, :uploaded_data].include?(k.to_sym) }
        # Need to be careful on this one... we can't let students turn in a
        # file and then edit it after the fact...
        params[:attachment].delete(:uploaded_data) if @context.is_a?(User)
        @attachment.attributes = params[:attachment]
        if just_hide == '1'
          @attachment.locked = false
          @attachment.hidden = true
        elsif hidden && (hidden.empty? || hidden == "0")
          @attachment.hidden = false
        end
        @attachment.folder = @folder
        @folder_id_changed = @attachment.folder_id_changed?
        if @attachment.save
          @attachment.move_to_bottom if @folder_id_changed
          flash[:notice] = 'File was successfully updated.'
          format.html { redirect_to named_context_url(@context, :context_files_url) }
          format.xml  { head :ok }
          format.json { render :json => @attachment.to_json(:methods => [:readable_size, :mime_class, :currently_locked], :permissions => {:user => @current_user, :session => session}), :status => :ok }
        else
          format.html { render :action => "edit" }
          format.xml  { render :xml => @attachment.errors.to_xml }
          format.json { render :json => @attachment.errors.to_json, :status => :bad_request }
        end
      end
    end
  end
  
  def reorder
    @folder = @context.folders.active.find(params[:folder_id])
    if authorized_action(@context, @current_user, :manage_files)
      @folders = @folder.sub_folders.active
      @folders.first && @folders.first.update_order((params[:folder_order] || "").split(","))
      @folder.file_attachments.first && @folder.file_attachments.first.update_order((params[:order] || "").split(","))
      @folder.reload
      render :json => @folder.subcontent.to_json(:methods => :readable_size, :permissions => {:user => @current_user, :session => session})
    end
  end
  
  def destroy
    @attachment = Attachment.find(params[:id])
    if authorized_action(@attachment, @current_user, :delete)
      @attachment.destroy
      respond_to do |format|
        format.html { redirect_to named_context_url(@context, :context_files_url) }# show.rhtml
        format.xml  { render :xml => @attachment.to_xml }
        format.json { render :json => @attachment.to_json }
      end
    end
  end
  
  def image_thumbnail
    cancel_cache_buster
    url = Rails.cache.fetch(['thumbnail_url', params[:uuid]].cache_key, :expires_in => 30.minutes) do
      attachment = Attachment.find_by_id_and_uuid(params[:id], params[:uuid])
      url = attachment.thumbnail_url rescue nil
      url ||= '/images/no_pic.gif'
      url
    end
    redirect_to url
  end
  
  def public_feed
    return unless get_feed_context
    feed = Atom::Feed.new do |f|
      f.title = "#{@context.name} Files Feed"
      f.links << Atom::Link.new(:href => named_context_url(@context, :context_files_url))
      f.updated = Time.now
      f.id = named_context_url(@context, :context_files_url)
    end
    @entries = []
    @entries.concat @context.attachments.active
    @entries = @entries.sort_by{|e| e.updated_at}
    @entries.each do |entry|
      feed.entries << entry.to_atom
    end
    respond_to do |format|
      format.atom { render :text => feed.to_xml }
    end    
  end
end
