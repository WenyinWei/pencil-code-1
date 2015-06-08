! This is a tool to check the correctness on the start.in and run.in file.
!
! $Id$
!****************************************************************************
program pc_configtest
!
  use Cdata
  use Cparam, only: fnlen, intlen
  use Diagnostics
  use File_io, only: file_exists
  use Filter
  use General, only: itoa
  use Grid, only: initialize_grid
  use IO
  use Messages
  use Param_IO
  use Particles_main
  use Register
  use Snapshot
  use Sub
  use Syscalls, only: sizeof_real
!
  implicit none
!
  real, dimension (mx,my,mz,mfarray) :: f
!
  lstart = .true.
  lmpicomm = .false.
  root = 0
  lroot = .true.
  ipx = 0
  ipy = 0
  ipz = 0
  ylneigh = 0
  zlneigh = 0
  yuneigh = 0
  zuneigh = 0
  llcorn = 0
  lucorn = 0
  uucorn = 0
  ulcorn = 0
!
!  Identify version.
!
  if (lroot) call svn_id( &
      '$Id$')
!
!  Initialize the message subsystem, eg. color setting etc.
!
  call initialize_messages()
!
!  Read parameters from start.x (default values; may be overwritten by
!  read_runpars).
!
  write (*,*) '>>> TESTING START.IN <<<'
  call read_startpars()
!
!  Read parameters and output parameter list.
!
  write (*,*) '>>> TESTING RUN.IN <<<'
  lstart = .false.
  lrun = .true.
  call read_runpars()
  lrun = .false.
  lstart = .true.
!
!  Derived parameters (that may still be overwritten).
!  [might better be put into another routine, possibly even in read_startpars
!  or read_runpars]
!
  x0 = xyz0(1)
  y0 = xyz0(2)
  z0 = xyz0(3)
  Lx = Lxyz(1)
  Ly = Lxyz(2)
  Lz = Lxyz(3)
!
! Calculate dimensionality
!
  dimensionality = min(nxgrid-1,1) + min(nygrid-1,1) + min(nzgrid-1,1)
!
!  Register physics modules.
!
  call register_modules()
  if (lparticles) call particles_register_modules()
!
!  Define the lenergy logical
!
  lenergy = lentropy .or. ltemperature .or. lthermal_energy
!
  if (lwrite_aux .and. .not. lread_aux) then
    if (lroot) then
      print *, ''
      print *, 'lwrite_aux=T but lread_aux=F'
      print *, 'The code will write the auxiliary variables to allprocs/VARN'
      print *, ' without having read them from proc*/VARN'
      print *, ''
      call fatal_error("pc_configtest","Stop and check")
    endif
  endif
!
!  Will we write all slots of f?
!
  if (lwrite_aux) then
    mvar_io=mvar+maux
  else
    mvar_io=mvar
  endif
!
!  Print resolution and dimension of the simulation.
!
  if (lroot) write (*,'(a,i1,a)') ' This is a ', dimensionality, '-D run'
  if (lroot) print *, 'nxgrid, nygrid, nzgrid=', nxgrid, nygrid, nzgrid
  if (lroot) print *, 'Lx, Ly, Lz=', Lxyz
  if (lroot) print *, 'Vbox=', Lxyz(1)*Lxyz(2)*Lxyz(3)
  if (lroot) write (*,*) 'mvar = ', mvar_io
!
!  Allow modules to do any physics modules do parameter dependent
!  initialization. And final pre-timestepping setup.
!  (must be done before need_XXXX can be used, for example)
!
  call initialize_modules(f)
  call particles_initialize_modules(f)
!
!  Set up flags for leading processors in each possible direction and plane
!
  lfirst_proc_x = (ipx == 0)
  lfirst_proc_y = (ipy == 0)
  lfirst_proc_z = (ipz == 0)
  lfirst_proc_xy = lfirst_proc_x .and. lfirst_proc_y
  lfirst_proc_yz = lfirst_proc_y .and. lfirst_proc_z
  lfirst_proc_xz = lfirst_proc_x .and. lfirst_proc_z
  lfirst_proc_xyz = lfirst_proc_x .and. lfirst_proc_y .and. lfirst_proc_z
!
!  Set up flags for trailing processors in each possible direction and plane
!
  llast_proc_x = (ipx == nprocx-1)
  llast_proc_y = (ipy == nprocy-1)
  llast_proc_z = (ipz == nprocz-1)
  llast_proc_xy = llast_proc_x .and. llast_proc_y
  llast_proc_yz = llast_proc_y .and. llast_proc_z
  llast_proc_xz = llast_proc_x .and. llast_proc_z
  llast_proc_xyz = llast_proc_x .and. llast_proc_y .and. llast_proc_z
!
!  Set up directory names 'directory' and 'directory_snap'.
!
  call directory_names()
!
!  Read coordinates.
!
  if (lrun) then
    if ((ip<=6) .and. lroot) print*, 'reading grid coordinates'
    call rgrid ('grid.dat')
!
! Size of box at local processor. The if-statement is for
! backward compatibility.
!
    if (all(lequidist)) then
      Lxyz_loc(1) = Lxyz(1) / nprocx
      Lxyz_loc(2) = Lxyz(2) / nprocy
      Lxyz_loc(3) = Lxyz(3) / nprocz
      xyz0_loc(1) = xyz0(1) + ipx*Lxyz_loc(1)
      xyz0_loc(2) = xyz0(2) + ipy*Lxyz_loc(2)
      xyz0_loc(3) = xyz0(3) + ipz*Lxyz_loc(3)
      xyz1_loc(1) = xyz0_loc(1) + Lxyz_loc(1)
      xyz1_loc(2) = xyz0_loc(2) + Lxyz_loc(2)
      xyz1_loc(3) = xyz0_loc(3) + Lxyz_loc(3)
    else
      xyz0_loc(1) = x(l1)
      xyz0_loc(2) = y(m1)
      xyz0_loc(3) = z(n1)
      xyz1_loc(1) = x(l2)
      xyz1_loc(2) = y(m2)
      xyz1_loc(3) = z(n2)
      Lxyz_loc(1) = xyz1_loc(1) - xyz0_loc(1)
      Lxyz_loc(2) = xyz1_loc(2) - xyz0_loc(3)
      Lxyz_loc(3) = xyz1_loc(3) - xyz0_loc(3)
    endif
!
!  Need to re-initialize the local grid for each processor.
!
    call initialize_grid()
  endif
!
!  Give all modules the possibility to exit properly.
!
  call finalize_modules (f)
!
!  Free any allocated memory.
!
  call fnames_clean_up()
  call vnames_clean_up()
  if (lparticles) call particles_cleanup()
!
  write (*,*) 'CONFIGTEST: > SUCCESSFUL <'
!
endprogram pc_configtest
