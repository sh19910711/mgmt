class DevicesController < ApplicationController
  before_action :auth, except: [:status, :image] # XXX: We need "device authentication"
  before_action :set_current_team, only: [:status, :image]

  def index
    devices = current_team.devices.select("name", "board", "status").all
    render json: { devices: devices }
  end

  def update
    device = current_team.devices.where(name: device_params[:name]).first
    if device == nil
      render status: :not_found, json: { error: "The device not found." }
      return
    end

    device.board  = device_params[:board]
    device.status = device_params[:status]
    device.tag    = device_params[:tag]
    device.save!
  end

  def status
    device = current_team.devices.where(name: device_params[:name]).first_or_initialize
    device.board  = device_params[:board]
    device.status = device_params[:status]
    device.save!

    deployment  = get_deployment(device_params[:name])
    latest_version = deployment ? deployment.id.to_s : 'X'
    render body: latest_version
  end

  def image
    if device_params[:deployment_id]
      # deployment ID can be specified by the client (device). Devices that
      # does not have enough memory downloads an image using Range.
      #
      # This prevents downloading a different image which have deployed
      # during downloading an older image.
      deployment = Deployment.find(device_params[:deployment_id])
      device = Device.find_by_name(device_params[:name])
      if device.apps == []
        return head :not_found
      end

      # TODO: support multi-apps
      if device.apps.first != deployment.app or
        deployment.board != device.board or
        (deployment.tag != nil and deployment.tag != device.tag)
        return head :not_found
      end
    else
      deployment = get_deployment(device_params[:name])
    end

    unless deployment
      return head :not_found
    end

    # TODO: replace send_file with a redirection
    # Since BaseOS does not support redirection we cannot use it.
    filepath = deployment.image.current_path
    filesize = File.size?(filepath)

    partial = false # send whole data by default
    if request.headers["Range"]
      m = request.headers['Range'].match(/bytes=(?<offset>\d+)-(?<offset_end>\d*)/)
      if m
        partial = true
        offset = m[:offset].to_i
        offset_end =  (m[:offset_end] == "") ? filesize : m[:offset_end].to_i
        length = offset_end - offset

        if offset < 0 || length < 0
          return head :bad_request
        end

        if offset + length > filesize || offset == filesize
          # Parsing Content-Length in BaseOS is hassle for me. Set X-End-Of-File
          # to indicate that BaseOS have downloaded whole file data.
          response.header['X-End-Of-File'] = "yes"
          return head :partial_content
        end
      end
    end

    if partial
      response.header['Content-Length'] = "#{length}"
      response.header['Content-Range']  = "bytes #{offset}-#{offset_end}/#{filesize}"
      send_data IO.binread(filepath, length, offset),
                status: :partial_content, disposition: "inline"
    else
      send_file deployment.image.current_path, status: :ok
    end
  end

  private

  def get_deployment(device_name)
    device = current_team.devices.find_by_name(device_name)
    unless device
      logger.info "the device not found"
      return nil
    end

    if device.apps == []
      logger.info "the device is not associated to an app"
      return nil
    end

    # TODO: support multi-apps
    app = device.apps.first

    deployment = Deployment.where(app: app,
                                  board: device.board,
                                  tag: [device.tag, nil]).order("created_at").last

    unless deployment
      logger.info "no deployments"
      return nil
    end

    deployment
  end

  def set_current_team
    # TODO: verify "device password"
    @current_team = User.find_by_name!(params[:team])
  end

  def device_params
    params.permit(:name, :board, :status, :tag)
  end
end
