! $Id: particles_nbody.f90,v 1.85 2008-03-20 22:25:24 wlyra Exp $
!
!  This module takes care of everything related to sink particles.
!
!** AUTOMATIC CPARAM.INC GENERATION ****************************
!
! Declare (for generation of cparam.inc) the number of f array
! variables and auxiliary variables added by this module
!
! CPARAM logical, parameter :: lparticles_nbody=.true.
!
!***************************************************************
module Particles_nbody

  use Cdata
  use Messages
  use Particles_cdata
  use Particles_sub

  implicit none

  include 'particles_nbody.h'

  real, dimension(nspar,mpvar+1) :: fsp
  integer, dimension(nspar) :: ipar_sink
  real, dimension(nspar) :: xsp0=0.0, ysp0=0.0, zsp0=0.0
  real, dimension(nspar) :: vspx0=0.0, vspy0=0.0, vspz0=0.0
  real, dimension(nspar) :: pmass=1.,r_smooth,pmass1,final_ramped_mass=1.
  real, dimension(nspar) :: accrete_hills_frac=0.2
  real :: delta_vsp0=1.0,totmass,totmass1
  character (len=labellen) :: initxxsp='random', initvvsp='nothing'
  logical :: lcalc_orbit=.true.,lbackreaction=.false.,lnorm=.true.
  logical :: lreset_cm=.false.,lnogravz_star=.false.,lexclude_frozen=.false.
  logical :: lnoselfgrav_star=.true.
  logical, dimension(nspar) :: lcylindrical_gravity_nbody=.false.
  logical, dimension(nspar) :: lfollow_particle=.false.,laccretion=.true.
  real :: GNewton=impossible,prhs_cte
  integer :: ramp_orbits=5
  logical :: lramp=.false.,lcreate_sinks=.false.
  logical :: linterpolate_gravity=.false.,linterpolate_linear=.true.
  logical :: linterpolate_quadratic_spline=.false.

  real :: create_jeans_constant=0.25,GNewton1
  real, pointer :: rhs_poisson_const

  integer :: iglobal_ggp=0,istar=1,imass=0

  integer :: maxsink=10*nspar,icreate=100

  namelist /particles_nbody_init_pars/ &
       initxxsp, initvvsp, xsp0, ysp0, zsp0, vspx0, vspy0, vspz0, delta_vsp0, &
       pmass, r_smooth, lcylindrical_gravity_nbody, &
       lexclude_frozen, GNewton, bcspx, bcspy, bcspz, &
       ramp_orbits,lramp,final_ramped_mass,prhs_cte,linterpolate_gravity,&
       linterpolate_quadratic_spline,laccretion,accrete_hills_frac,istar,&
       maxsink,lcreate_sinks,icreate

  namelist /particles_nbody_run_pars/ &
       dsnap_par_minor, linterp_reality_check, lcalc_orbit, lreset_cm, &
       lnogravz_star,lfollow_particle, lbackreaction, lexclude_frozen, &
       GNewton, bcspx, bcspy, bcspz,prhs_cte,lnoselfgrav_star,&
       linterpolate_quadratic_spline,laccretion,accrete_hills_frac,istar,&
       maxsink,lcreate_sinks,icreate

  integer, dimension(nspar,3) :: idiag_xxspar=0,idiag_vvspar=0
  integer, dimension(nspar)   :: idiag_torqint=0,idiag_torqext=0
  integer                     :: idiag_totenergy=0,idiag_totangmom=0

  logical :: ldust=.false.

  contains

!***********************************************************************
    subroutine register_particles_nbody()
!
!  Set up indices for access to the f and fsp
!
!  27-aug-06/wlad: adapted
!
      use Messages, only: fatal_error, cvs_id
!
      logical, save :: first=.true.
!
      if (.not. first) &
          call fatal_error('register_particles_nbody: called twice','')
      first = .false.
!
      if (lroot) call cvs_id( &
           "$Id: particles_nbody.f90,v 1.85 2008-03-20 22:25:24 wlyra Exp $")
!
! Set up mass as particle index. Plus seven, since the other 6 are 
! used by positions and velocities.      
!
      imass=npvar+1
!
!  No need to solve the N-body equations for non-N-body problems.
!
      if (nspar < 2) then
        if (lroot) write(0,*) 'nspar = ', nspar
        call fatal_error('register_particles_nbody','the number of massive'//&
             ' particles is less than 2. There is no need to use the'//&
             ' N-body code. Consider setting gravity as a global variable'//&
             ' using gravity_r.f90 instead.')
      endif
!
!  Check that we aren't registering too many auxiliary variables
!
      if (naux > maux) then
        if (lroot) write(0,*) 'naux = ', naux, ', maux= ', maux
        call fatal_error('register_particles_nbody','naux > maux')
      endif
!
    endsubroutine register_particles_nbody
!***********************************************************************
    subroutine initialize_particles_nbody(lstarting)
!
!  Perform any post-parameter-read initialization i.e. calculate derived
!  parameters.
!
!  27-aug-06/wlad: adapted
!
      use Mpicomm,only:stop_it
      use FArrayManager
      use SharedVariables
!
      integer :: ierr,ks
      logical :: lstarting
!
      if (initxxsp=='nothing') then
        !nothing, no particles yet
        mspar=0
      else
        mspar=nspar
        !when first called, mspar was zero, so no diagnostic 
        !index was written to index.pro
        if (lroot) open(3, file=trim(datadir)//'/index.pro', &
             STATUS='old', POSITION='append')
        call rprint_particles_nbody(.false.,LWRITE=lroot)
        if (lroot) close(3)
      endif
!
! G_Newton. Overwrite the one set by start.in if set again here, 
! because I might want units in which both G and GM are 1. 
! If we are solving for selfgravity, get that one instead
!
      if (GNewton == impossible) then
        !ONLY REASSIGN THE GNEWTON 
        !IF IT IS NOT SET IN START.IN!!!!!
        if (lselfgravity) then 
          call get_shared_variable('rhs_poisson_const',rhs_poisson_const,ierr)
          if (ierr/=0) then
            if (lroot) print*, 'initialize_particles_nbody: '// &
                 'there was a problem when getting rhs_poisson_const!'
            call fatal_error('initialize_particles_nbody','')
          endif
          GNewton=rhs_poisson_const/(4*pi)
        else
          GNewton=G_Newton
        endif
      endif
!
      GNewton1=1./GNewton
!
! inverse mass
!
      if (lramp) then
        do ks=1,mspar
          if (ks/=istar) pmass(ks) = epsi
        enddo
        pmass(istar)=1-epsi*(mspar-1)
      endif
!
      pmass1=1./pmass
!
! inverse total mass
!
      totmass=sum(pmass)
      totmass1=1./totmass
!
! check for consistency between the cylindrical gravities switches
! from cdata and the one from nbody
!
      if (((lcylindrical_gravity).and.&
        (.not.lcylindrical_gravity_nbody(istar))).or.&
             (.not.lcylindrical_gravity).and.&
             (lcylindrical_gravity_nbody(istar))) then 
        call stop_it("initialize_particles_nbody: inconsitency "//&
             "between lcylindrical_gravity from cdata and the "//&
             "one from nbody")
      endif
!
      if (rsmooth.ne.r_smooth(istar)) then 
        call stop_it("initialize_particles_nbody: inconsitency "//&
             "between rsmooth from cdata and the "//&
             "one from nbody")
      endif
!
! Check for consistency between the poisson and integral 
! calculations of selfgravity
!
      if (lbackreaction.and.lselfgravity) then 
        print*,'self-gravity is already taken into '//&
             'account. lbackreaction is a way of '//&
             'integrating the self-gravity only in few '//&
             'specific points of the grid'
        call fatal_error("initialize_particles_nbody","")
      endif
!
!  The presence of dust particles needs to be known
!
      if (npar > nspar) ldust=.true.
      if (linterpolate_gravity.and.(.not.ldust)) then 
        if (lroot) print*,'interpolate gravity is just'//&
             ' for the dust component. No need for it if'//&
             ' you are not using dust particles'
        call fatal_error("initialize_particles_nbody","")
      endif
      if (any(laccretion).and.linterpolate_gravity) then 
        if (lroot) print*,'interpolate gravity  not yet '//&
             'implemented in connection with accretion'
        call fatal_error("initialize_particles_nbody","")
      endif
      
      if (linterpolate_gravity) then
         if (lroot) print*,'initializing global array for sink gravity'
         call farray_register_global('ggp',iglobal_ggp,vector=3)
      endif
!      
      if (linterpolate_quadratic_spline) &
           linterpolate_linear=.false.
!
      if ((.not.linterpolate_gravity).and.&
           linterpolate_quadratic_spline) then
        if (lroot) print*,'no need for linterpolate_quadratic_spline'//&
             'if linterpolate_gravity is false'
        call fatal_error("initialize_particles_nbody","")
      endif
!
    endsubroutine initialize_particles_nbody
!***********************************************************************
    subroutine pencil_criteria_par_nbody()
!
!  All pencils that the Particles_nbody module depends on are specified here.
!
!  22-sep-06/wlad: adapted
!
      lpenc_requested(i_rho)=.true.
      if (ldust) lpenc_requested(i_rhop)=.true.
      lpenc_requested(i_r_mn)=.true.
      lpenc_requested(i_rcyl_mn)=.true.
      
      
      if (idiag_totenergy/=0) then
        lpenc_diagnos(i_u2)=.true.
        lpenc_diagnos(i_rcyl_mn)=.true.
      endif
!
      if (any(idiag_torqext/=0) .or. any(idiag_torqint/=0)) then
        lpenc_diagnos(i_rcyl_mn)=.true.
      endif
!
    endsubroutine pencil_criteria_par_nbody
!***********************************************************************
    subroutine pencil_interdep_par_nbody(lpencil_in)
!
!  Interdependency among pencils provided by the Particles_nbody module
!  is specified here.
!
!  22-sep-06/wlad: adapted
!
      logical, dimension(npencils) :: lpencil_in
!
      if (NO_WARN) print*, lpencil_in
!
    endsubroutine pencil_interdep_par_nbody
!***********************************************************************
    subroutine calc_pencils_par_nbody(f,p)
!
!  Calculate sink particle pencils
!
!  22-sep-06/wlad: adapted
!
      real, dimension (mx,my,mz,mfarray) :: f
      type (pencil_case) :: p
!
      if (NO_WARN) print*, f, p
!
    endsubroutine calc_pencils_par_nbody
!***********************************************************************
    subroutine init_particles_nbody(f,fp)
!
!  Initial positions and velocities of sink particles.
!  Overwrite the position asserted by the dust module
!
!  17-nov-05/anders+wlad: adapted
!
      use General, only: random_number_wrapper
      use Sub
      use Mpicomm
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mpar_loc,mpvar) :: fp
      integer, dimension (mpar_loc,3) :: ineargrid
      real, dimension(mspar) :: ang_vel,kep_vel,sma
      real, dimension(mspar,3) :: position,velocity
      real :: tmp,tmp2,rr,fac,parc
      integer :: k,ks

      intent (in) :: f
      intent (out) :: fp
!
!  Initialize particles' positions and velocities
!
      position(:,1) = xsp0 ; position(:,2) = ysp0 ; position(:,3) = zsp0
      velocity(:,1) = vspx0; velocity(:,2) = vspy0; velocity(:,3) = vspz0
!
      select case(initxxsp)

      case ('nothing')
        if (lroot) print*, 'init_particles_nbody: nothing'

      case ('origin')
        if (lroot) then
          print*, 'init_particles_nbody: All sink particles at origin'
          fp(1:mspar,ixp:izp)=0.
        endif
!
      case('constant')
        if (lroot) then
          print*, 'init_particles_nbody: All sink particles at x,y,z=', xsp0, ysp0, zsp0
          fp(1:mspar,ixp)=xsp0
          fp(1:mspar,iyp)=ysp0
          fp(1:mspar,izp)=zsp0
        endif
!
      case ('random')
        if (lroot) print*, 'init_particles_nbody: Random particle positions'
        do ks=1,mspar
          if (nxgrid/=1) call random_number_wrapper(position(ks,ixp))
          if (nygrid/=1) call random_number_wrapper(position(ks,iyp))
          if (nzgrid/=1) call random_number_wrapper(position(ks,izp))
        enddo

        if (nxgrid/=1) &
             position(1:mspar,ixp)=xyz0_loc(1)+position(1:mspar,ixp)*Lxyz_loc(1)
        if (nygrid/=1) &
             position(1:mspar,iyp)=xyz0_loc(2)+position(1:mspar,iyp)*Lxyz_loc(2)
        if (nzgrid/=1) &
             position(1:mspar,izp)=xyz0_loc(3)+position(1:mspar,izp)*Lxyz_loc(3)
!
!  Loop through ipar to allocate the sink particles
!
        do k=1,npar_loc
          if (ipar(k) <= mspar) then
            print*,'initparticles_nbody. Slot for sink particle ',ipar(k),&
                 ' was at fp position ',k,' at processor ',iproc
!
            fp(k,ixp:izp)=position(ipar(k),1:3)
!
! Correct for non-existing dimensions (not really needed, I think)
!
            if (nxgrid==1) fp(k,ixp)=x(nghost+1)
            if (nygrid==1) fp(k,iyp)=y(nghost+1)
            if (nzgrid==1) fp(k,izp)=z(nghost+1)
!
            print*,'initparticles_nbody. Sink particle ',ipar(k),&
                 ' located at ixp=',fp(k,ixp)
          endif
        enddo
!
      case ('fixed-cm')
!
        if (lgrav) then
          print*,"a gravity module is being used. Are you using "//&
                 "both a fixed central gravity and nbody gravity? "//&
                 "better stop and check"
          call stop_it("init_particles_nbody")
        endif
!
! Ok, I have the masses and the positions of all sinks except the last, 
! which will have a position determined to fix the center of mass on 
! the center of the grid
!
        if (any(ysp0/=0)) then
          if (lspherical_coords) then
            call stop_it("init_particles_nbody: not yet generalized"//&
                 " for non-zero initial inclinations")
          else
            call stop_it("init_particles_nbody: not yet generalized"//&
                 " for non-zero azimuthal initial position")
          endif
        endif
        if (any(zsp0/=0)) then  
          if (lspherical_coords) then
            call stop_it("init_particles_nbody: not yet generalized"//&
                 " for non-zero azimuthal initial position")
          else
            call stop_it("init_particles_nbody: nbody code not"//&
                 " yet generalized to allow initial inclinations")
          endif
        endif
        if (lcylindrical_coords.or.lspherical_coords) then
          if (any(xsp0.lt.0)) &
               call stop_it("init_particles_nbody: in cylindrical coordinates"//&
               " all the radial positions must be positive")
        endif
!
        if (lroot) then
          print*,'fixed-cm: redefining the mass of the last sink particle'
          print*,'fixed-cm: it assumes that the sum of the mass'//&
               ' of the particles is always g0'
        endif
!
        if (lspherical_coords) then
          if (lroot) print*,'put all particles in the midplane'
          position(1:mspar,iyp)=pi/2
        endif
!
        tmp = 0.;parc=0
        do ks=1,mspar
          if (ks/=istar) then 
            sma(ks)=abs(position(ks,1))
            tmp=tmp+pmass(ks)
            parc = parc - sma(ks)*pmass(ks)
          endif
        enddo
        pmass(istar)=1.- tmp;pmass1=1./pmass;totmass=1.;totmass1=1.
        parc = parc*totmass1
        if (tmp .ge. 1.) &
             call stop_it("particles_nbody,init_particles. The mass of one "//& 
             "(or more) of the particles is too big! The masses should "//&
             "never be bigger than g0. Please scale your assemble so that "//&
             "the combined mass of the (n-1) particles is less than that. "//&
             "The mass of the last particle in the pmass array will be "//&
             "reassigned to ensure that the total mass is g0")
!
        do ks=1,mspar
          if (ks/=istar) &
               position(ks,1)=sign(1.,position(ks,1))* (sma(ks) + parc)
        enddo
!
! The last one (star) fixes the CM at Rcm=zero
!
        if (lcartesian_coords) then 
          position(istar,1)=parc
        elseif (lcylindrical_coords) then
          !put the star in positive coordinates, with pi for azimuth
          position(istar,1)=abs(parc)
          position(istar,2)=pi
        elseif (lspherical_coords) then
          position(istar,1)=abs(parc)
          position(istar,3)=pi
        endif
!
        if (lroot) then 
          print*,'pmass =',pmass
          print*,'position (x)=',position(:,1)
          print*,'position (y)=',position(:,2)
          print*,'position (z)=',position(:,3)
        endif
!
! Loop through ipar to allocate the sink particles
!
        do k=1,npar_loc
          if (ipar(k) <= mspar) then
!
            print*,'initparticles_nbody. Slot for sink particle ',ipar(k),&
                 ' was at fp position ',k,' at processor ',iproc
!
            fp(k,ixp:izp)=position(ipar(k),1:3)
!
! Correct for non-existing dimensions (not really needed, I think)
!
            if (nxgrid==1) fp(k,ixp)=x(nghost+1)
            if (nygrid==1) fp(k,iyp)=y(nghost+1)
            if (nzgrid==1) fp(k,izp)=z(nghost+1)
!
            print*,'initparticles_nbody. Sink particle ',ipar(k),&
                 ' located at ixp=',fp(k,ixp)
          endif
        enddo
!
      case default
        if (lroot) print*,"init_particles: No such such value for"//&
             " initxxsp: ",trim(initxxsp)
        call stop_it("")
!
      endselect
!
!  Redistribute particles among processors (now that positions are determined).
!
      call boundconds_particles(fp,npar_loc,ipar)
!
!  Initial particle velocity.
!
      select case(initvvsp)

      case ('nothing')
        if (lroot) print*, 'init_particles: No particle velocity set'
      case ('zero')
        if (lroot) then
          print*, 'init_particles: Zero particle velocity'
          fp(1:mspar,ivpx:ivpz)=0.
        endif
!
      case ('constant')
         if (lroot) then
           print*, 'init_particles: Constant particle velocity'
           print*, 'init_particles: vspx0, vspy0, vspz0=', vspx0, vspy0, vspz0
           fp(1:mspar,ivpx)=vspx0
           fp(1:mspar,ivpy)=vspy0
           fp(1:mspar,ivpz)=vspz0
         endif
!
      case ('fixed-cm')
!
! Keplerian velocities for the planets
!
        parc=0.
        do ks=1,mspar
          if (ks/=istar) then
            kep_vel(ks)=sqrt(1./sma(ks)) !circular velocity
            parc = parc - kep_vel(ks)*pmass(ks)
          endif
        enddo
        parc = parc*totmass
        do ks=1,mspar
          if (ks/=istar) then 
            if (lcartesian_coords) then
              velocity(ks,2) = sign(1.,position(ks,1))*(kep_vel(ks) + parc)
            elseif (lcylindrical_coords) then
              !positive for the planets
              velocity(ks,2) = abs(kep_vel(ks) + parc)
            elseif (lspherical_coords) then
              velocity(ks,3) = abs(kep_vel(ks) + parc)
            endif
          endif
        enddo
!
! The last one (star) fixes the CM also with velocity zero
!
        if (lcartesian_coords) then 
          velocity(istar,2)=parc
        elseif (lcylindrical_coords) then 
          velocity(istar,2)=-parc
        elseif (lspherical_coords) then 
          velocity(istar,3)=-parc
        endif
!
! Loop through ipar to allocate the sink particles
!
         do k=1,npar_loc
           if (ipar(k)<=mspar) then
             print*,&
                  'initparticles_nbody. Slot for sink particle ',ipar(k),&
                  ' was at fp position ',k,&
                  ' at processor ',iproc
!
             fp(k,ivpx:ivpz) = velocity(ipar(k),1:3)
!
             print*,'initparticles_nbody. Sink particle ',ipar(k),&
                  ' has velocity y=',fp(k,ivpy)
!
           endif
         enddo
!
      case default
        if (lroot) print*, "init_particles: No such such value for"//&
             "initvvsp: ",trim(initvvsp)
        call stop_it("")
!
      endselect
!
! Make the particles known to all processors
!
      call boundconds_particles(fp,npar_loc,ipar)
      call share_sinkparticles(fp)
!
    endsubroutine init_particles_nbody
!***********************************************************************
    subroutine dvvp_dt_nbody_pencil(f,df,fp,dfp,p,ineargrid)
!
!  Add gravity from the particles to the gas
!  and the backreaction from the gas onto the particles
!
!  Adding the gravity on the dust component via the grid
!  is less accurate, but much faster than looping through all 
!  npar_loc particle and add the gravity of all sinks to it.
!
!  07-sep-06/wlad: coded
!
      use Messages, only: fatal_error
      use Sub
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx,my,mz,mvar) :: df
      real, dimension (mpar_loc,mpvar) :: fp, dfp
      real, dimension (nx,mspar) :: rp_mn,rpcyl_mn
      real, dimension (mx,3) :: ggt
      real, dimension (nx) :: pot_energy
      real, dimension (3) :: xxpar,accg
      type (pencil_case) :: p
      integer, dimension (mpar_loc,3) :: ineargrid
      integer :: ks,k
      logical :: lintegrate,lparticle_out
!
      intent (in) :: f, p, fp, ineargrid
      intent (inout) :: df,dfp
!
! Get the total gravity field. In the case of dust,
! it is already pre-calculated
!
      if (linterpolate_gravity) then
!
! Interpolate the gravity to the position of the particles
!
          if (npar_imn(imn)/=0) then
            do k=k1_imn(imn),k2_imn(imn) !loop throught in the pencil
              if (ipar(k).gt.mspar) then !for dust
                !interpolate the gravity
                if (linterpolate_linear) then
                  call interpolate_linear(f,iglobal_ggp,&
                       iglobal_ggp+2,fp(k,ixp:izp),accg,ineargrid(k,:),ipar(k))
                else if (linterpolate_quadratic_spline) then
                  !
                  ! WL: I am not sure if this interpolation
                  !     works for cylindrical coordinates, so
                  !     beware
                  !
                  call interpolate_quadratic_spline(f,iglobal_ggp,&
                       iglobal_ggp+2,fp(k,ixp:izp),accg,ineargrid(k,:),ipar(k))
                endif
                dfp(k,ivpx:ivpz)=dfp(k,ivpx:ivpz)+accg
              endif
            enddo
          endif
        endif
! 
! Add the acceleration to the gas
!
      if (lhydro) then
        if (linterpolate_gravity) then
          !already calculate, so no need to lose time
          !calculating again
          ggt=f(:,m,n,iglobal_ggp:iglobal_ggp+2)
        else
          call get_total_gravity(ggt)
        endif
        df(l1:l2,m,n,iux:iuz) = df(l1:l2,m,n,iux:iuz) + ggt(l1:l2,:)       
!
! Backreaction of the gas+dust gravity onto the massive particles
! The integration is needed for these two cases:
!  
!   1. We are not solving the Poisson equation (lbackreaction)
!   2. We are, but a particle is out of the box (a star, for instance)
!      and therefore the potential cannot be interpolated.
!
        do ks=1,mspar
          lparticle_out=.false.
          if (lselfgravity) then
            if ((fsp(ks,ixp)< xyz0(1)).or.(fsp(ks,ixp) > xyz1(1)) .or. &
                (fsp(ks,iyp)< xyz0(2)).or.(fsp(ks,iyp) > xyz1(2)) .or. &
                (fsp(ks,izp)< xyz0(3)).or.(fsp(ks,izp) > xyz1(3))) then 
              !particle out of box
              lparticle_out=.true.
            endif
          endif
          lintegrate=lbackreaction.or.lparticle_out
!
! Sometimes making the star feel the selfgravity of the disk
! leads to numerical troubles as the star is too close to the 
! origin (in cylindrical coordinates).
!
          if ((ks==istar).and.lnoselfgrav_star) &
               lintegrate=.false.
!
          if (lintegrate) then
!
! Get the acceleration particle ks suffers due to self-gravity
!
            xxpar = fsp(ks,ixp:izp)
            if (lcylindrical_gravity_nbody(ks)) then
              call integrate_selfgravity(p,rpcyl_mn(:,ks),&
                   xxpar,accg,r_smooth(ks))
            else
              call integrate_selfgravity(p,rp_mn(:,ks),&
                   xxpar,accg,r_smooth(ks))
            endif
            
!
! Add it to its dfp
!
            do k=1,npar_loc
              if (ipar(k)==ks) &
                   dfp(k,ivpx:ivpz) = dfp(k,ivpx:ivpz) + accg(1:3)
            enddo
          endif
!
! Diagnostic
!
          if (ldiagnos) then
            if (idiag_totenergy/=0) pot_energy=0.
            call get_radial_distance(rp_mn(:,ks),rpcyl_mn(:,ks),&
                 E1_=fsp(ks,ixp),E2_=fsp(ks,iyp),E3_=fsp(ks,izp))
!
! Calculate torques for output, if needed
!
            if ((idiag_torqext(ks)/=0).or.(idiag_torqint(ks)/=0)) &
                 call calc_torque(p,rpcyl_mn(:,ks),ks)
!
! Total energy      
!
            if (idiag_totenergy/=0) then
              !potential energy
              pot_energy = pot_energy - &
                   GNewton*pmass(ks)*&
                   (rpcyl_mn(:,ks)**2+r_smooth(ks)**2)**(-0.5)
              if (ks==mspar) &
                   call sum_lim_mn_name(.5*p%rho*p%u2 + pot_energy,&
                   idiag_totenergy,p)
            endif
          endif
        enddo
      endif
!
    endsubroutine dvvp_dt_nbody_pencil
!***********************************************************************
    subroutine dxxp_dt_nbody(dfp)
!
!  If the center of mass of the sink particles was moved from the
!  center of the grid, reset it.
!
!  22-sep-06/wlad: coded
!
      real, dimension (mpar_loc,mpvar) :: dfp
!
      if (lreset_cm) &
           call reset_center_of_mass(dfp)
!
    endsubroutine dxxp_dt_nbody
!***********************************************************************
    subroutine dvvp_dt_nbody(f,df,fp,dfp,ineargrid)
!
!  Evolution of sink and dust particles velocities due to
!  particle-particle interaction only. 
!
!  Coriolis and shear already added in particles_dust
!
!  27-aug-06/wlad: coded
!
      use Cdata
      use Mpicomm, only: mpibcast_real,stop_it
      use Sub
!
      real, dimension (mx,my,mz,mfarray) :: f
      real, dimension (mx,my,mz,mvar) :: df
      real, dimension (mpar_loc,mpvar) :: fp, dfp
      integer, dimension (mpar_loc,3) :: ineargrid
!
      real, dimension(mspar) :: sq_hills
      real :: rr,w2,sma2
!
      integer :: k, ks, j, jpos, jvel
      logical :: lheader, lfirstcall=.true.
!
      intent (in) ::     f,  ineargrid
      intent (inout) :: fp, df, dfp
!
!  Print out header information in first time step.
!
      lheader=lfirstcall .and. lroot
!
!  Identify module.
!
      if (lheader) print*,'dvvp_dt_nbody: Calculate dvvp_dt_nbody'
!
!  Evolve sink particle positions due to the gravity of other 
!  sink particles. The gravity of the sinks on the dust will be
!  added inside the pencil in dvvp_dt_nbody_pencil
!
      if (lramp) call get_ramped_mass
!
! Calculate Hills radius if laccretion is switched on      
!
      do ks=1,mspar 
        if (laccretion(ks).and.(ks/=istar)) then 
          if (lcartesian_coords) then
            rr    = sqrt(fsp(ks,ixp)**2 + fsp(ks,iyp)**2 + fsp(ks,izp)**2)
          elseif (lcylindrical_coords) then 
            rr= fsp(ks,ixp)
            if (nzgrid/=1) rr=sqrt(fsp(ks,ixp)**2+fsp(ks,izp)**2)
          elseif (lspherical_coords) then
           rr= fsp(ks,ixp)
          endif
          !particle velocities are non-coordinate (linear)
          w2    = fsp(ks,ivpx)**2 + fsp(ks,ivpy)**2 + fsp(ks,ivpz)**2
          !squared semi major axis - assumes GM=1, so beware...
          sma2  = (rr/(2-rr*w2))**2
          !squared hills radius
          sq_hills(ks)=sma2*(pmass(ks)*pmass1(istar)/3)**(2./3.)
        else
          sq_hills(ks)=0.
        endif
      enddo
!
      do k=npar_loc,1,-1
        if (linterpolate_gravity) then
          !only loop through sinks
          if (ipar(k).le.mspar) then
            call loop_through_sinks(fp,dfp,k,sq_hills,ineargrid)
          endif
        else
          !for all particles
          call loop_through_sinks(fp,dfp,k,sq_hills,ineargrid)
        endif
      enddo
!
!  Position and velocity diagnostics (per sink particle)
! 
     if (ldiagnos) then
        do ks=1,mspar
          if (lfollow_particle(ks)) then
            do j=1,3
              jpos=j+ixp-1 ; jvel=j+ivpx-1
              if (idiag_xxspar(ks,j)/=0) &
                   call point_par_name(fsp(ks,jpos),idiag_xxspar(ks,j))
              if (idiag_vvspar(ks,j)/=0) &
                   call point_par_name(fsp(ks,jvel),idiag_vvspar(ks,j))
            enddo
          endif
        enddo
      endif
!
      if (lfirstcall) lfirstcall=.false.
!
    endsubroutine dvvp_dt_nbody
!************************************************************
    subroutine loop_through_sinks(fp,dfp,k,sq_hills,ineargrid)
!
      real, dimension (mpar_loc,mpvar) :: fp,dfp
      real, dimension (mspar) :: sq_hills
      real, dimension (3) :: evr
      integer, dimension (mpar_loc,3) :: ineargrid
      real :: r2_ij,rs2,invr3_ij
      integer :: k, ks
!
      intent(inout) :: fp,dfp
      intent(in)  :: k
!
      do ks=1,mspar
        if (ipar(k)/=ks) then
!
          call get_particles_interdistance(&
               fp(k,ixp:izp),fsp(ks,ixp:izp),&
               VECTOR=evr,DISTANCE=r2_ij,lsquare=.true.)
!
!  Particles relative distance from each other
!
!  r_ij = sqrt(ev1**2 + ev2**2 + ev3**2)
!  invr3_ij = r_ij**(-3)
!
          rs2=(accrete_hills_frac(ks)**2)*sq_hills(ks)

          if (laccretion(ks).and.(r2_ij.le.rs2)) then
            call remove_particle(fp,npar_loc,ipar,k,dfp,ineargrid)
            !add mass to the planet
            !calculate...
            goto 99
          else
            r2_ij=r2_ij+r_smooth(ks)**2
            invr3_ij = r2_ij**(-1.5)
!
!  Gravitational acceleration: g=g0/|r-r0|^3 (r-r0)
!  The acceleration is in non-coordinate basis (all have dimension of length). 
!  The main dxx_dt of particle_dust takes care of 
!  transforming the linear velocities to angular changes 
!  in position.
!
            dfp(k,ivpx:ivpz) = dfp(k,ivpx:ivpz) - &
                 GNewton*pmass(ks)*invr3_ij*evr(1:3)
          endif
!
        endif
      enddo
!
99    continue
      
    endsubroutine loop_through_sinks
!**********************************************************
    subroutine point_par_name(a,iname)
!
!  Register a, a simple scalar, as diagnostic.
!  Works for individual particle diagnostics. 
!
!  07-mar-08/wlad: adapted from sum_par_name
!
      use Cdata
!
      real ::  a
      integer :: iname
!
      if (iname/=0) then
        fname(iname)=a
      endif
!
!  There is no entry in itype_name.
!
    endsubroutine point_par_name
!***********************************************************************
    subroutine read_particles_nbody_init_pars(unit,iostat)
!
      integer, intent (in) :: unit
      integer, intent (inout), optional :: iostat
!
      if (present(iostat)) then
        read(unit,NML=particles_nbody_init_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=particles_nbody_init_pars,ERR=99)
      endif
!
99    return
!
    endsubroutine read_particles_nbody_init_pars
!***********************************************************************
    subroutine write_particles_nbody_init_pars(unit)
!
      integer, intent (in) :: unit
!
      write(unit,NML=particles_nbody_init_pars)
!
    endsubroutine write_particles_nbody_init_pars
!***********************************************************************
    subroutine read_particles_nbody_run_pars(unit,iostat)
!
      integer, intent (in) :: unit
      integer, intent (inout), optional :: iostat
!
      if (present(iostat)) then
        read(unit,NML=particles_nbody_run_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=particles_nbody_run_pars,ERR=99)
      endif
!
99    return
!
    endsubroutine read_particles_nbody_run_pars
!***********************************************************************
    subroutine write_particles_nbody_run_pars(unit)
!
      integer, intent (in) :: unit
!
      write(unit,NML=particles_nbody_run_pars)
!
    endsubroutine write_particles_nbody_run_pars
!***********************************************************************
    subroutine reset_center_of_mass(dfp)
!
!  If the center of mass was accelerated, reset its position
!  to the center of the grid. Must be called by a dxxp_dt_nbody?
!
!  Assumes that the total mass of the particles is one.
!
!  27-aug-06/wlad: coded
!  18-mar-08/wlad: cylindrical and spherical corrections
!
      use Mpicomm,only:stop_it
!
      real, dimension(mpar_loc,mpvar),intent(inout) :: dfp
      real, dimension(3) :: vcm
      real :: xcm,ycm,zcm,thtcm,phicm,vxcm,vycm,vzcm
      integer :: k
!
      if (lcartesian_coords) then 
        vcm(1) = sum(pmass*fsp(:,ivpx))
        vcm(2) = sum(pmass*fsp(:,ivpy))
        vcm(3) = sum(pmass*fsp(:,ivpz))
      else if (lcylindrical_coords) then
        xcm=sum(pmass*(fsp(:,ipx)*cos(fsp(:,iyp))))
        ycm=sum(pmass*(fsp(:,ipx)*sin(fsp(:,iyp))))
        phicm=atan2(ycm,xcm)
        vxcm=sum(pmass*(&
             fsp(:,ivpx)*cos(fsp(:,iyp))-fsp(:,ivpy)*sin(fsp(:,iyp))&
                                                                    ))
        vycm=sum(pmass*(&
             fsp(:,ivpx)*sin(fsp(:,iyp))+fsp(:,ivpy)*cos(fsp(:,iyp))&
                                                                    ))
        !
        vcm(1)= vxcm*cos(phicm) + vycm*sin(phicm)
        vcm(2)=-vxcm*sin(phicm) + vycm*cos(phicm)
        vcm(3) = sum(pmass*fsp(:,ivpz))
      else if (lspherical_coords) then
        vxcm=sum(pmass*( &
              fsp(:,ivpx)*sin(fsp(:,iyp))*cos(fsp(:,izp))&
             +fsp(:,ivpy)*cos(fsp(:,iyp))*cos(fsp(:,izp))&
             -fsp(:,ivpz)*sin(fsp(:,izp))                ))
        vycm=sum(pmass*( &
              fsp(:,ivpx)*sin(fsp(:,iyp))*sin(fsp(:,izp))&
             +fsp(:,ivpy)*cos(fsp(:,iyp))*sin(fsp(:,izp))&
             +fsp(:,ivpz)*cos(fsp(:,izp))                ))

        vzcm=sum(pmass*(&
             fsp(:,ivpx)*cos(fsp(:,iyp))-fsp(:,ivpy)*sin(fsp(:,iyp))&
                                                               ))
!
        xcm=sum(pmass*(fsp(:,ixp)*sin(fsp(:,iyp))*cos(fsp(:,izp))))
        ycm=sum(pmass*(fsp(:,ixp)*sin(fsp(:,iyp))*sin(fsp(:,izp))))
        zcm=sum(pmass*(fsp(:,ixp)*cos(fsp(:,iyp))))
!        
        thtcm=atan2(sqrt(xcm**2+ycm**2),zcm)
        phicm=atan2(ycm,xcm)
!
        vcm(1)= vxcm*sin(thtcm)*cos(phicm) + vycm*sin(thtcm)*sin(phicm) + vzcm*cos(thtcm) 
        vcm(2)= vxcm*cos(thtcm)*cos(phicm) + vycm*cos(thtcm)*sin(phicm) - vzcm*sin(thtcm) 
        vcm(3)=-vxcm*sin(phicm)            + vycm*cos(phicm) 
      endif
!
      do k=1,npar_loc
        if (ipar(k)<=mspar) then
          dfp(k,ixp:izp) = dfp(k,ixp:izp) - vcm*totmass1
        endif
      enddo
!
    endsubroutine reset_center_of_mass
!***********************************************************************
    subroutine integrate_selfgravity(p,rrp,xxpar,accg,rp0)
!
! Calculates acceleration on the point (x,y,z)=xxpar
! due to the gravity of the gas+dust.
!
! 15-sep-06/wlad : coded
!
      use Mpicomm
!
      real, dimension(nx,3) :: dist
      real, dimension(nx) :: rrp,selfgrav,density
      real, dimension(nx) :: dv,jac,dqy,tmp
      real :: dqx,dqz,rp0,fac
      real, dimension(3) :: xxpar,accg,sum_loc
      integer :: k,j
      type (pencil_case) :: p      
      logical :: lfirstcall=.true.
!
      intent(out) :: accg
!
      if (lfirstcall) &
           print*,'Adding gas+dust gravity to the massive particles'
!
      if (coord_system=='cartesian') then
        jac=1.;dqx=dx;dqy=dy;dqz=dz
        dist(:,1)=x(l1:l2)-xxpar(1)
        dist(:,2)=y(  m  )-xxpar(2)
        dist(:,3)=z(  n  )-xxpar(3)
      elseif (coord_system=='cylindric') then
        jac=x(l1:l2);dqx=dx;dqy=x(l1:l2)*dy;dqz=dz
        dist(:,1)=x(l1:l2)-xxpar(1)*cos(y(m)-xxpar(2))
        dist(:,2)=         xxpar(2)*sin(y(m)-xxpar(2))
        dist(:,3)=z(  n  )-xxpar(3)
      elseif (coord_system=='spherical') then
        call stop_it("integrate_selfgravity: "//&
             " not yet implemented for spherical polars")
      endif

      if (nzgrid==1) then
        dv=dqx*dqy
      else
        dv=dqx*dqy*dqz
      endif
!
! The gravity of every single cell - should exclude inner and outer radii...
!
! selfgrav = G*((rho+rhop)*dv)*mass*r*(r**2 + r0**2)**(-1.5)
! gx = selfgrav * r\hat dot x\hat
! -> gx = selfgrav * (x-x0)/r = G*((rho+rhop)*dv)*mass*(r**2+r0**2)**(-1.5) * (x-x0)
!
      density=0.
      if (ldust) then !npar>mspar equals dust is being used
        density=density+p%rhop
      else
        density=density+p%rho
      endif
      selfgrav = prhs_cte*density*jac*dv*(rrp**2 + rp0**2)**(-1.5)
!
! Everything inside the accretion radius of the particle should
! not exert gravity (numerical problems otherwise)
!
      where (rrp.le.rp0)
        selfgrav = 0
      endwhere
!
! Exclude the frozen zones
!
      if (lexclude_frozen) then
        if (lcylinder_in_a_box) then
          where ((p%rcyl_mn.le.r_int).or.(p%rcyl_mn.ge.r_ext))
            selfgrav = 0
          endwhere
        else
          where ((p%r_mn.le.r_int).or.(p%r_mn.ge.r_ext))
            selfgrav = 0
          endwhere
        endif
      endif
!
! Integrate the accelerations on this processor
! And sum over processors with mpireduce
!
      do j=1,3
        tmp=selfgrav*dist(:,j)
        !take proper care of the trapezoidal rule
        !in the case of non-periodic boundaries
        fac = 1.
        if ((m==m1.and.ipy==0).or.(m==m2.and.ipy==nprocy-1)) then
          if (.not.lperi(2)) fac = .5*fac
        endif
!
        if (lperi(1)) then
          sum_loc(j) = fac*sum(tmp)
        else
          sum_loc(j) = fac*(sum(tmp(2:nx-1))+.5*(tmp(1)+tmp(nx)))
        endif
        call mpireduce_sum_scl(sum_loc(j),accg(j))
      enddo
!
!  Broadcast particle acceleration
!
      call mpibcast_real(accg,3)
!
      if (lfirstcall) lfirstcall=.false.
!
    endsubroutine integrate_selfgravity
!***********************************************************************
    subroutine share_sinkparticles(fp)
!
! Broadcast sink particles across processors
! The non-root processors, if they find a sink particle in their
! fp array, they:
!    send it to root with a true logical
!    else send a false logical
!
! The root processor receives all the logicals, and if
! they are true, then receives the value, broadcasting it
!
! 07-sep-06/wlad: coded
!
      use Mpicomm
!
      real, dimension(mpar_loc,mpvar) :: fp
      logical, dimension(mspar) :: lsink
      integer :: ks,k,tagsend,j,tagrecv
!
      if (lmpicomm) then
!
! Loop through the sink particles
!
        do ks=1,mspar
!
! Set the logical to false initially
!
          lsink(ks)=.false.
!
! Loop through the particles on this processor
!
          do k=1,npar_loc
            if (ks==ipar(k)) then
!
! A sink was found here. Turn the logical true and copy fp to fsp
!
              lsink(ks) = .true.
              fsp(ks,ixp:ivpz) = fp(k,:)
!
! Send it to root. As there will be just mspar calls to
! mpisend, the tag can be ipar itself
!
              if (.not.lroot) then
                call mpisend_real(fsp(ks,:),mpvar,root,ks)
                if (ip<=6) print*,'logical for particle ',ks,&
                     ' set to true on processor ',iproc, &
                     ' with tag=',ks
              endif
            endif
          enddo
!
! Send the logicals from each processor. As all processors send mspar calls,
! the tags are now in base mspar. It assures that two logicals will not have
! the same tag.
!
          if (.not.lroot) then
            tagsend = mspar*iproc + ks
            call mpisend_logical(lsink(ks),1,root,tagsend)
          else
!
! The root receives all logicals. Same tag.
!
            do j=1,ncpus-1
              tagrecv = mspar*j + ks
              call mpirecv_logical(lsink(ks),1,j,tagrecv)
!
! Test the received logicals
!
              if (lsink(ks)) then
!
! Found a sink particle. Get the value of fsp
!
                call mpirecv_real(fsp(ks,:),mpvar,j,ks)
                if (ip<=6) print*,'logical for particle ',ks,&
                     ' is true on processor ',j, &
                     ' with tag=',ks,' on root'
              endif
            enddo
          endif
!
! Broadcast the received fsp
!
          call mpibcast_real(fsp(ks,:),mpvar)
!
! Print the result in all processors
!
          if (ip<=8)  print*,'share_sinkparticles: finished loop. '//&
               'sink particles in proc ',iproc,&
               ' are fsp(ks,:)=',fsp(ks,:)
        enddo
      else
!
! Non-parallel. Just copy fp to fsp
!
        do k=1,npar_loc
          if (ipar(k)<=mspar) fsp(ipar(k),ixp:ivpz) = fp(k,:)
        enddo
!
      endif
!
    endsubroutine share_sinkparticles
!***********************************************************************
    subroutine get_totalmass(tmass)
!
! called from global_shear to set the initial keplerian field
!
      real :: tmass
!
      if (lnorm) then 
        tmass=1.
      else
        tmass=sum(pmass)
      endif
!   
    endsubroutine get_totalmass
!***********************************************************************
    subroutine get_gravity_field_nbody(grr,gg,ks)

      use Cdata,only: coord_system,x,y,z,l1,l2,&
                      m,n,nx,lcylindrical_gravity
      use Mpicomm,only:stop_it
!
      real, dimension(mx),intent(in) :: grr
      real, dimension(mx,3),intent(out) :: gg
      real :: x0,y0,z0
      integer :: ks
!
      x0=fsp(ks,ixp);y0=fsp(ks,iyp);z0=fsp(ks,izp)
!
      if (coord_system=='cartesian') then
        gg(:,1) = (x   -x0)*grr
        gg(:,2) = (y(m)-y0)*grr
        gg(:,3) = (z(n)-z0)*grr
      elseif (coord_system=='cylindric') then
        gg(:,1) = (x   -x0*cos(y(m)-y0))*grr
        gg(:,2) =       x0*sin(y(m)-y0) *grr
        gg(:,3) = (z(n)-z0             )*grr
      elseif (coord_system=='spherical') then
        gg(:,1)  = (x-x0*sin(y(m))*sin(y0)*cos(z(n)-z0))*grr
        gg(:,2)  = (x0*(sin(y(m))*cos(y0)-&
             cos(y(m))*sin(y0)*cos(z(n)-z0)))*grr
        gg(:,3)  = (x0*sin(y0)*sin(z(n)-z0))*grr
      endif
!
    endsubroutine get_gravity_field_nbody
!***********************************************************************
    subroutine calc_torque(p,dist,ks)
!
!  Output torque diagnostic for sink particle ks
!
!  05-nov-05/wlad : coded
!
      use Sub
      use Mpicomm, only: stop_it
!
      type (pencil_case) :: p
      real, dimension(nx) :: torque,torqint,torqext
      real, dimension(nx) :: dist,rpre
      real :: rr,w2,smap,hills
      integer :: ks,i
!
      if (.not.lcartesian_coords) &
           call stop_it("particles_nbody: calc_torque not yet "//&
           "implemented for curvilinear coordinates.")
!
      if (ks==istar) &
           call stop_it("Nonsense to calculate torques for the star")

      rr    = sqrt(fsp(ks,ixp)**2 + fsp(ks,iyp)**2 + fsp(ks,izp)**2)
      w2    = fsp(ks,ivpx)**2 + fsp(ks,ivpy)**2 + fsp(ks,ivpz)**2
      smap  = 1./(2./rr - w2)
      hills = smap*(pmass(ks)*pmass1(istar)/3.)**(1./3.)
!
      rpre  = fsp(ks,ixp)*y(m) - fsp(ks,iyp)*x(l1:l2)
      torque = GNewton*pmass(ks)*p%rho*rpre*&
           (dist**2 + r_smooth(ks)**2)**(-1.5)
!
      torqext=0.
      torqint=0.
!
      do i=1,nx
!
! Exclude material from inside the Roche Lobe
!
        if (dist(i).ge.hills) then
!
! External torque
!
          if (p%rcyl_mn(i).ge.rr) torqext(i) = torque(i)
!
! Internal torque
!
          if (p%rcyl_mn(i).le.rr) torqint(i) = torque(i)
!
        endif
!
      enddo
!
      call sum_lim_mn_name(torqext,idiag_torqext(ks),p)
      call sum_lim_mn_name(torqint,idiag_torqint(ks),p)
!
    endsubroutine calc_torque
!***********************************************************************
    subroutine get_ramped_mass
!     
      real :: ramping_period,tmp
      integer :: ks
!
      ramping_period=2*pi*ramp_orbits
      if (t .le. ramping_period) then
        !sin ((pi/2)*(t/(ramp_orbits*2*pi))
        tmp=0.
        do ks=1,mspar
          if (ks/=istar) then 
            pmass(ks)= max(tini,&
                 final_ramped_mass(ks)*(sin((.5*pi)*(t/ramping_period))**2))
            tmp=tmp+pmass(ks)
          endif
        enddo
        pmass(istar)= 1-tmp
      else
        pmass=final_ramped_mass
      endif
!
    endsubroutine get_ramped_mass
!***********************************************************************
    subroutine calc_nbodygravity_particles(f)
!
      real, dimension(mx,my,mz,mfarray) :: f
      real, dimension(mx,3) :: ggt
!
      if (linterpolate_gravity) then
!
        if (lramp) call get_ramped_mass
!
! Calculate grid - sink particles distances
!
        do n=1,mz
          do m=1,my
            call get_total_gravity(ggt)
            f(:,m,n,iglobal_ggp:iglobal_ggp+2)=ggt
          enddo
        enddo
!
!  else do nothing
!
      endif
!
    endsubroutine calc_nbodygravity_particles
!***********************************************************************
    subroutine get_total_gravity(ggt)
!  
      use Sub
!
      real, dimension (mx,mspar) :: rp_mn,rpcyl_mn
      real, dimension (mx,3)     :: ggp,ggt
      real, dimension (mx)       :: grav_particle,rrp
      integer                    :: ks
!
      intent(out) :: ggt
!
      ggt=0.
      do ks=1,mspar
!
! Spherical and cylindrical distances
!
        call get_radial_distance(rp_mn(:,ks),rpcyl_mn(:,ks),&
             e1_=fsp(ks,ixp),e2_=fsp(ks,iyp),e3_=fsp(ks,izp))
!
! Check which particle has cylindrical gravity switched on
!
        if (lcylindrical_gravity_nbody(ks)) then
          rrp = rpcyl_mn(:,ks)
        else
          rrp = rp_mn(:,ks)
        endif
!
! Gravity field from the particle ks
!
        grav_particle =-GNewton*pmass(ks)*(rrp**2+r_smooth(ks)**2)**(-1.5)
        call get_gravity_field_nbody(grav_particle,ggp,ks)
!
        if ((ks==istar).and.lnogravz_star) &
             ggp(:,3) = 0.
!
! Sum up the accelerations of the sinks
!
        ggt=ggt+ggp
!
      enddo
!
    endsubroutine get_total_gravity
!***********************************************************************
    subroutine create_sink_particles(f,fp,ineargrid)
!
      use EquationOfState, only: cs20
      use FArrayManager,   only: farray_use_global
!
      real, dimension(mx,my,mz,mfarray) :: f
      real, dimension(mpar_loc,mpvar) :: fp
      real, dimension(maxsink,mpvar+1) :: fcsp
      real, dimension(nx,3) :: vvpm
      real, dimension(nx) :: rho_jeans,rho_jeans_dust,vpm2
      real, dimension(nx) :: Delta1
!
      integer, dimension(nx,mpar_loc) :: pik
      integer, dimension(mpar_loc,3) :: ineargrid
      integer :: i,k,kn,inx0,nc
      integer, pointer :: iglobal_cs2

      logical :: ltime_to_create
!
      real, dimension(nx)  ::prho,prhop,pcs2
      integer, dimension(nx) :: pnp
      real, dimension(nx,3)::puu
!
      if (lcreate_sinks) then
        ltime_to_create=mod(it-1,icreate).eq.0
        if (ltime_to_create) then
!
          do i=1,nx
            if (lcartesian_coords) then 
              Delta1(i)=max(dx_1(i),dy_1(mpoint),dz_1(npoint))
            elseif (lcylindrical_coords) then 
              Delta1(i)=max(dx_1(i),rcyl_mn1(i)*dy_1(mpoint),dz_1(npoint))
            elseif (lspherical_coords) then 
              call fatal_error("create_sink_particle","not yet implemented"//&
                   "for spherical polars")
            endif
          enddo
!
! start number of created particles
!
          fcsp=0.
          nc=0
!
          do n=n1,n2
            do m=m1,m2
!
! define the "pencils"
!
              if (ldensity_nolog) then 
                prho=f(l1:l2,m,n,ilnrho)
              else
                prho=exp(f(l1:l2,m,n,ilnrho))
              endif
!
              if (ldust)  then 
                prhop=f(l1:l2,m,n,irhop)
                pnp  =int(f(l1:l2,m,n,inp))
              endif
!
              if (lhydro) puu=f(l1:l2,m,n,iux:iuz)
!
              if (llocal_iso) then 
                call farray_use_global('cs2',iglobal_cs2)
                pcs2=f(l1:l2,m,n,iglobal_cs2)
              else
                pcs2=cs20
              endif
!
! Jeans analysis of the Gas
!
! The Jeans length is lambda_J = sqrt(pi*cs2/(G*rho))
! We substitute lambda_J by the biggest resolution 
! element and write the condition in terms of density
!
!    rho_J = pi*cs2/G*Delta_x^2 
!
! The constant is a free parameter of the module
!
              if (nzgrid/=1) then 
                rho_jeans = create_jeans_constant*3.*pi*pcs2*GNewton1*Delta1**2/32 
              else
                rho_jeans = create_jeans_constant*   pi*pcs2*GNewton1*Delta1   /8
              endif
!
              do i=1,nx
                if (prho(i).gt.rho_jeans(i)) then 
!
! create a new particle at the center of the grid
!
                  nc=nc+1
!
! check if we are not creating too many particles
!
                  if (nc>maxsink) then
                    print*,'too many sink particles were created. '//&
                         'Stop and allocated more'
                    print*,'nc,maxsink=',nc,maxsink
                    call fatal_error("create_sink_particles","")
                  endif
!
                  fcsp(nc,ixp) = x(i+nghost)
                  fcsp(nc,iyp) = y(m)
                  fcsp(nc,izp) = z(n)
!
! give it the velocity of the grid cell
!
                  fcsp(nc,ivpx:ivpz) = puu(i,:)
!          
! the mass of the new particle is the 
! collapsed mass m=[rho - rho_jeans]*dV
!
                  fcsp(nc,imass)   = (prho(i)-rho_jeans(i))*dvolume(i)
!
! and that amount was lost by the grid, so only rho_jeans remains
!
                  if (ldensity_nolog) then 
                    f(i+nghost,m,n,ilnrho) = rho_jeans(i)
                  else 
                    f(i+nghost,m,n,ilnrho) = log(rho_jeans(i))
                  endif
!         
                endif
              enddo
!
! Jeans analysis of the dust
! 
              if (ldust) then 
!
! Have to get k1s,k2s and ineargrids...
!

!
! Substitute sound speed for vpm2=<(vvp-<vvp>)^2>, the particle's velocity 
! dispersion 
!
                vvpm=0.0; vpm2=0.0
                do k=k1_imn(imn),k2_imn(imn)
                  inx0=ineargrid(k,1)-nghost
                  vvpm(inx0,:) = vvpm(inx0,:) + fp(k,ivpx:ivpz)
                enddo
                do i=1,nx
                  if (pnp(i)>1.0) &
                       vvpm(i,:)=vvpm(i,:)/pnp(i)
                enddo
! vpm2
                do k=k1_imn(imn),k2_imn(imn)
                  inx0=ineargrid(k,1)-nghost
                  vpm2(inx0) = vpm2(inx0) + (fp(k,ivpx)-vvpm(inx0,1))**2 + &
                       (fp(k,ivpy)-vvpm(inx0,2))**2 + &
                       (fp(k,ivpz)-vvpm(inx0,3))**2 
                enddo
                do i=1,nx
                  if (pnp(i)>1.0) then
                    vpm2(i)=vpm2(i)/pnp(i)
                  endif
                enddo
!
                if (nzgrid/=1) then 
                  rho_jeans_dust = create_jeans_constant*3*pi*vpm2*GNewton1*Delta1**2/32 
                else
                  rho_jeans_dust = create_jeans_constant*  pi*vpm2*GNewton1*Delta1   /8
                endif
!
! Which particle is in which cell?
!
                do k=k1_imn(imn),k2_imn(imn)
                  inx0=ineargrid(k,1)-nghost
                  if (pnp(inx0) > 1.0) then 
                    do kn=1,pnp(inx0) 
                      pik(inx0,kn) = k
                    enddo
                  endif
                enddo
!
                do i=1,nx
                  if (prhop(i).gt.rho_jeans_dust(i)) then 
!
! remove all particles from the cell
!
                    do kn=1,pnp(i) 
                      call remove_particle(fp,npar_loc,ipar,pik(i,kn))
                    enddo
!
! create a new particle at the center of the grid
!
                    nc=nc+1
!
! check if we are not making too many particles
!
                    if (nc>maxsink) then
                      print*,'too many sink particles were created. '//&
                           'Stop and allocated more'
                      print*,'nc,maxsink=',nc,maxsink
                      call fatal_error("create_sink_particles","")
                    endif
!
                    fcsp(nc,ixp) = x(i+nghost)
                    fcsp(nc,iyp) = y(m)
                    fcsp(nc,izp) = z(n)
!
! give it the mean velocity of the group of particles that 
! was accreted
!
                    fcsp(nc,ivpx:ivpz) = vvpm(i,:)
!          
! the mass of the new particle is the 
! collapsed mass M=m_particle*np
!
                    fcsp(nc,imass)    = mp_tilde*pnp(i)
!         
                  endif
                enddo
!
              endif !if (ldust)
        
            enddo
          enddo
!
! Finished creating them. Now merge the particles and share across
! processors to the fp array. 
!
          if (nc/=0) &
               call merge_and_share(fcsp,nc,fp)
!
        endif
      endif
!
    endsubroutine create_sink_particles
!**************************************************************************
    subroutine merge_and_share(fcspp,nc,fp)
!     
      use Mpicomm
!
      real, dimension(mpar_loc,mpvar) :: fp
      real, dimension(maxsink,mpvar+1) :: fcspp,fcsp_proc,fcsp
      real, dimension(nspar,mpvar+1) :: fleft
!
      integer :: nc,nc_proc,ncr,nf,kc,j

      real, dimension(0:ncpus-1,nspar,mpvar) :: fcsp_mig
      integer, dimension(0:ncpus-1) :: nsmig
      integer :: iz0,iy0,ipz_rec,ipy_rec,iproc_rec
      integer:: ns,np,i
      double precision :: dy1,dz1
!
! Send the info about all the created particles to 
! the root processor
!
      if (lmpicomm) then 
        if (.not.lroot) then 
          call mpisend_int(nc,1,root,222)
          call mpisend_real(fcspp(1:nc,:),(/nc,mpvar+1/),root,111)
        else
          ncr=nc !lroot's nc
          fcsp=fcspp
          do j=1,ncpus-1
            call mpirecv_int(nc_proc,1,j,222)
            call mpirecv_real(fcsp_proc(1:nc_proc,:),(/nc_proc,mpvar+1/),j,111)
            fcsp(ncr+1:ncr+nc_proc,:)=fcsp_proc(1:nc_proc,:)
            ncr=ncr+nc_proc
          enddo
        endif
      else
        !serial, just copy it
        ncr =nc
        fcsp=fcspp
      endif
!
! The root processor merges them with the friends of friends algorithm
!
      if (lroot) then
        call friends_of_friends(fcsp,fleft,ncr,nf)
!
! Friends of friends merged the created particles into few massive
! clusters. These new clusters are truly sinks.
!
        mspar=mspar+nf
!
! But check if we did not end up with too many particles
!
        if (mspar>nspar) then 
          print*,'after friends_of_friends, we still have '//&
               'too many sink particles.'//&
               'Stop and allocated more'
          call fatal_error("merge and share","")
        endif
      endif
!      
      call mpibcast_int(mspar,1)
!
! Migrate the particles to their respective processors
!
      if (lmpicomm) then
        if (lroot) then
          dy1=1/dy; dz1=1/dz
          !y0_mig=0.5*(y(m1)+y(m1-1)); y1_mig=0.5*(y(m2)+y(m2+1))
          !z0_mig=0.5*(z(n1)+z(n1-1)); z1_mig=0.5*(z(n2)+z(n2+1))
          do kc=1,nf
            ipy_rec=ipy
            iy0=nint((fleft(kc,iyp)-y(m1))*dy1+nygrid)-nygrid+1
            do while (iy0>ny)
              ipy_rec=ipy_rec+1
              iy0=iy0-ny
            enddo
!            
            ipz_rec=ipz
            iz0=nint((fleft(kc,izp)-z(n1))*dz1+nzgrid)-nzgrid+1
            do while (iz0>nz)
              ipz_rec=ipz_rec+1
              iz0=iz0-nz
            enddo
        !  Calculate serial index of receiving processor.
            iproc_rec=ipy_rec+nprocy*ipz_rec
            if (iproc_rec>=ncpus .or. iproc_rec<0) then
              call warning('merge_and_share','',iproc)
              print*, 'merge_and_share: receiving proc does not exist'
              print*, 'merge_and_share: iproc, iproc_rec=', &
                   iproc, iproc_rec
              call fatal_error_local("","")
            endif
            if (iproc_rec/=iproc) then
          !prepare for migration
              nsmig(iproc_rec)=nsmig(iproc_rec)+1
              fcsp_mig(iproc_rec,nsmig(iproc_rec),:)=fleft(kc,1:mpvar)
            else
              !the particle is in the root processor
              !create the particle here
              npar_loc=npar_loc+1
              fp(npar_loc,:)=fleft(kc,1:mpvar)
              ipar(npar_loc)=npar_loc
            endif
          enddo
        
    !info about migrating sinks particles
          do j=1,ncpus-1
            call mpisend_int(nsmig(j), 1, j, 111)
          enddo
        else
          call mpirecv_int(nsmig(iproc), 1, root, 111)
        endif
! directed send
        if (lroot) then
          do j=1,ncpus-1
            ns=nsmig(j)
            if (ns/=0) &
                 call mpisend_real(fcsp_mig(j,1:ns,:), (/ns,mpvar/), j, 222)
          enddo
        else
          np=npar_loc
          ns=nsmig(iproc)
          if (ns/=0) then
            call mpirecv_real(fp(np+1:np+ns,:),(/ns,mpvar/),root,222)
            do kc=1,ns
              npar_loc=npar_loc+1
              ipar(npar_loc)=npar_loc
            enddo
          endif
        endif
      else
        do kc=1,nf
          npar_loc=npar_loc+1
          fp(npar_loc,:)=fleft(kc,1:mpvar)
          ipar(npar_loc)=npar_loc
        enddo
      endif
!
    endsubroutine merge_and_share
!***********************************************************************
    subroutine friends_of_friends(fcsp,fleft,nc,nfinal)
!
      real,    dimension(maxsink,mpvar+1) :: fcsp
      real,    dimension(nspar,mpvar+1)   :: fleft
      integer, dimension(nc,nc)           :: clusters 
      integer, dimension(nc)              :: cluster 
      logical, dimension(nc)              :: lchecked
      real, dimension(mpvar+1)            :: particle
      
      integer :: ks,nc,kf,nclusters,nf,i,nfinal
      integer :: min_number_members,kpar

      intent(in)  :: nc
      intent(out) :: nfinal,fleft
!
      min_number_members=3
!
!  All particles are initially unchecked
!
      lchecked(1:nc)=.false.
!
!  No clusters yet, counter is zero 
!
      nclusters=0 
!
!  And the final number of particles is the same as the initial
!
      kf=0
!
! Loop through the particles to cluster them
!
      do ks=1,nc
        if (.not.lchecked(ks)) then
!
! If a particle is unchecked particle, start a new cluster
!
          call make_cluster(ks,lchecked,cluster,nc,nf,fcsp)
!
! Cluster done, check if the number of particles is enough
!          
          if (nf >= min_number_members) then
!
! Okay, it is a cluster, raise the counter
!
            nclusters=nclusters+1 
            clusters(1:nf,nclusters)=cluster(1:nf)
!
! Collapse the cluster into a single sink particle
!
            call collapse_cluster(cluster,nf,fcsp,particle)
!
! this is all a single particle
!
            kf=kf+1
            fleft(kf,:)=particle
!
          else
            !this (or these) are isolated sinks
            do i=1,nf
              kf=kf+1
              kpar=cluster(i)
              fleft(kf,:)=fcsp(kpar,:)
            enddo
          endif
!
        endif
      enddo
!
      nfinal=kf
!
    endsubroutine friends_of_friends
!***********************************************************************
    subroutine make_cluster(ks,lchecked,cluster,nc,nf,fcsp)
!
      real,    dimension(maxsink,mpvar+1)   :: fcsp
      integer, intent(inout), dimension(nc) :: cluster 
      logical, intent(inout), dimension(nc) :: lchecked
      integer, intent(in)  :: ks,nc
      integer, intent(out) :: nf
!
      integer :: ic
!
! Start the cluster counter
!
      ic=0 
!
! Tag the particles as checked. The subroutine will also
! loop through its friends and friends of friends
!
      call check_particle(ks,lchecked,cluster,ic,nc,fcsp)
!
! When it ends this loop, the cluster is done. Nf is the final 
! number of members in the cluster
!
      nf=ic
!
    endsubroutine make_cluster
!***********************************************************************
    subroutine check_particle(k,lchecked,cluster,ic,nc,fcsp)
!
      real,    dimension(maxsink,mpvar+1)   :: fcsp
      integer, intent(inout), dimension(nc) :: cluster 
      logical, intent(inout), dimension(nc) :: lchecked
      integer, intent(inout) :: ic
      integer, intent(in) :: k,nc
!
! Add the particle to the cluster
!
      ic=ic+1
      cluster(ic)=k
!
! Tag it as visited and add its friends to the cluster 
! as well
!
      lchecked(k)=.true.
      call add_friends(k,lchecked,cluster,ic,nc,fcsp)
!
    endsubroutine check_particle
!***********************************************************************
    subroutine add_friends(par,lchecked,cluster,ic,nc,fcsp)
!
      real,    dimension(maxsink,mpvar+1)   :: fcsp
      logical, intent(inout), dimension(nc) :: lchecked
      integer, intent(inout), dimension(nc) :: cluster
      integer, intent(inout)                :: ic
      integer, intent(in)                   :: par,nc
!
      real, dimension(3) :: evr
      real    :: e1,e2,e3,e10,e20,e30
      real    :: dist,link_length
      integer :: k      
!
! linking length 
!
      link_length=4.*dx
!
! Loop through the particle
!
      do k=1,nc 
        if (.not.lchecked(k)) then 
          call get_particles_interdistance(&
               fcsp(k,ixp:izp),fcsp(par,ixp:izp),&
               DISTANCE=dist)

          if (dist.le.link_length) then 
!
! if so, add it to the cluster, tag it and call its friends
!
            call check_particle(k,lchecked,cluster,ic,nc,fcsp)
          endif
!
! done
! 
        endif
      enddo
!
    endsubroutine add_friends
!***********************************************************************
    subroutine collapse_cluster(cluster,nf,fcsp,particle)
!
      real,    dimension(maxsink,mpvar+1)   :: fcsp
      integer, intent(inout), dimension(nf) :: cluster
      real, dimension(mpvar+1) :: particle
      integer :: ic,nf,k

      real :: mass,xcm,ycm,vxcm,vycm
      real, dimension(3) :: position,velocity,xxp,vvp

!
      intent(in) :: nf
      intent(out):: particle
!
! collapse the cluster into a single particle
! with the total mass, momentum and energy of the 
! collapsed stuff
!
      mass=0;position=0;velocity=0
!
      do ic=1,nf
        k=cluster(ic)
        mass=mass+fcsp(k,imass)
        if (lcartesian_coords) then 
          xxp(1)=fcsp(k,ixp) ; vvp(1)=fcsp(k,ivpx)
          xxp(2)=fcsp(k,iyp) ; vvp(2)=fcsp(k,ivpy)
          xxp(3)=fcsp(k,izp) ; vvp(3)=fcsp(k,ivpz)
        else if (lcylindrical_coords) then
          xxp(1)=fcsp(k,ixp)*cos(fcsp(k,iyp))
          xxp(2)=fcsp(k,ixp)*sin(fcsp(k,iyp))
          xxp(3)=fcsp(k,izp)
!
          vvp(1)=fcsp(k,ivpx)*cos(fcsp(k,iyp))-fcsp(k,ivpy)*sin(fcsp(k,iyp))
          vvp(2)=fcsp(k,ivpx)*sin(fcsp(k,iyp))+fcsp(k,ivpy)*cos(fcsp(k,iyp))
          vvp(3)=fcsp(k,ivpz)
        else if (lspherical_coords) then
          call fatal_error("","")
        endif
        position=position+fcsp(k,imass)*xxp
        velocity=velocity+fcsp(k,imass)*vvp
      enddo
!
      position=position/mass
      if (lcylindrical_coords) then
        xcm=position(1);vxcm=velocity(1)
        ycm=position(2);vycm=velocity(2)
        position(1)=sqrt(xcm**2+ycm**2)
        position(2)=atan2(ycm,xcm)
!        
        velocity(1)= vxcm*cos(position(2))+vycm*sin(position(2))
        velocity(2)=-vxcm*sin(position(2))+vycm*cos(position(2))
      endif
!      
! put it onto the output array      
!
      particle(ixp : izp)=position
      particle(ivpx:ivpz)=velocity
      particle(imass)    =mass
!
    endsubroutine collapse_cluster
!***********************************************************************
    subroutine rprint_particles_nbody(lreset,lwrite)
!
!  Read and register print parameters relevant for sink particles.
!
!  17-nov-05/anders+wlad: adapted
!
      use Cdata
      use Sub, only: parse_name
      use General, only: chn
!
      logical :: lreset,lwr
      logical, optional :: lwrite
!
      integer :: iname,ks,j
      character :: str
      character (len=5) :: sks
!
!  Write information to index.pro
!
      lwr = .false.
      if (present(lwrite)) lwr=lwrite
!
!  Reset everything in case of reset
!
      if (lreset) then
        idiag_xxspar=0;idiag_vvspar=0
        idiag_torqint=0;idiag_torqext=0
        idiag_totenergy=0;idiag_totangmom=0
      endif
!
!  Run through all possible names that may be listed in print.in
!
      if (lroot .and. ip<14) print*,'rprint_particles: run through parse list'
!
!  Now check diagnostics for specific particles
!
      do ks=1,mspar
        call chn(ks,sks)
        do j=1,3
          if (j==1) str='x';if (j==2) str='y';if (j==3)  str='z'
          do iname=1,nname
            call parse_name(iname,cname(iname),cform(iname),&
                 trim(str)//'par'//trim(sks),idiag_xxspar(ks,j))
            call parse_name(iname,cname(iname),cform(iname),&
                 'v'//trim(str)//'par'//trim(sks),idiag_vvspar(ks,j))
          enddo
!
!  Run through parse list again
!
          if (lwr) then
            write(3,*) ' i_'//trim(str)//'par'//trim(sks)//'=',&
                 idiag_xxspar(ks,j)
            write(3,*) 'i_v'//trim(str)//'par'//trim(sks)//'=',&
                 idiag_vvspar(ks,j)
          endif
!
        enddo
!
        do iname=1,nname
          call parse_name(iname,cname(iname),cform(iname),&
               'torqint_'//trim(sks),idiag_torqint(ks))
          call parse_name(iname,cname(iname),cform(iname),&
               'torqext_'//trim(sks),idiag_torqext(ks))
        enddo
!
        if (lwr) then
          write(3,*) 'i_torqint_'//trim(sks)//'=',idiag_torqint(ks)
          write(3,*) 'i_torqext_'//trim(sks)//'=',idiag_torqext(ks)
        endif
      enddo
!
      do iname=1,nname
        call parse_name(iname,cname(iname),cform(iname),&
             'totenergy',idiag_totenergy)
        call parse_name(iname,cname(iname),cform(iname),&
             'totangmom',idiag_totangmom)
      enddo
!
     if (lwr) then
       write(3,*) 'i_totenergy=',idiag_totenergy
       write(3,*) 'i_totangmom=',idiag_totangmom
     endif
!
   endsubroutine rprint_particles_nbody
!***********************************************************************
 endmodule Particles_nbody
